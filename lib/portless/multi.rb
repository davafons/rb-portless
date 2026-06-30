# frozen_string_literal: true

module Portless
  # Run several apps under one proxy, each at its own `<name>.<tld>`, from the
  # `apps` map in portless.json. Every app gets a free backend port, a route, and
  # injected PORT/HOST/PORTLESS_URL; all run in their own process groups and are
  # supervised + torn down together. Ruby sets env per-spawn, so there's no
  # NODE_OPTIONS loader hack (cf. portless's turbo.ts).
  class Multi
    include RunSupport

    App = Struct.new(:name, :hostname, :port, :url, :pid, keyword_init: true)

    def initialize(config: Config.load, route_store: RouteStore.new)
      @config = config
      @route_store = route_store
      @apps = []
    end

    def run
      raise Error, "no apps defined — add an \"apps\" map to portless.json" if @config.apps.empty?

      ensure_trusted
      proxy_port = Daemon.ensure_running(tls: @config.tls)
      @apps = @config.apps.map { |name, command| start_app(name, command, proxy_port) }

      Banner.multi(apps: @apps)
      install_signal_handlers
      Process.waitall
    ensure
      teardown
    end

    private

    def start_app(name, command, proxy_port)
      port = FreePort.find
      hostname = "#{name}.#{@config.tld}"
      url = display_url(hostname, proxy_port)
      @route_store.add(hostname: hostname, port: port, pid: Process.pid, force: true)
      # A bare command string runs through the shell (handles "bin/rails server").
      pid = Process.spawn(child_env(port, url), command, pgroup: true)
      App.new(name: name, hostname: hostname, port: port, url: url, pid: pid)
    end

    def install_signal_handlers
      %w[INT TERM].each { |sig| trap(sig) { kill_all(sig) } }
    end

    def kill_all(sig)
      @apps.each do |app|
        Process.kill(sig, -Process.getpgid(app.pid))
      rescue StandardError
        nil
      end
    end

    def teardown
      @apps.each { |app| @route_store.remove(app.hostname, owner_pid: Process.pid) }
      kill_all("TERM")
    end
  end
end
