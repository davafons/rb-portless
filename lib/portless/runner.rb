# frozen_string_literal: true

module Portless
  # `portless-rb run <cmd>`: pick a free backend port, inject PORT/HOST, ensure
  # the proxy is up, register the named route, run the child in its own process
  # group (forwarding signals), and deregister on exit. Rails/puma respect PORT
  # natively. Mirrors portless's runApp/spawnCommand.
  class Runner
    def initialize(command:, config: Config.load, route_store: RouteStore.new)
      @command = Array(command)
      @config = config
      @route_store = route_store
    end

    def run
      command = resolved_command
      raise Error, "nothing to run — pass a command, e.g. portless-rb run bin/dev" if command.empty?

      port = @config.app_port&.to_i || FreePort.find
      hostname = @config.hostname
      url = "#{@config.tls ? 'https' : 'http'}://#{hostname}"

      Daemon.ensure_running(tls: @config.tls)
      @route_store.add(hostname: hostname, port: port, pid: Process.pid, force: true)

      announce(url, port)
      status = supervise(command, port, url)
      exit(status)
    ensure
      @route_store.remove(hostname, owner_pid: Process.pid) if hostname
    end

    private

    # Run the child in its own process group so we can signal the whole tree,
    # forwarding INT/TERM and propagating its exit status.
    def supervise(command, port, url)
      child = Process.spawn(child_env(port, url), *command, pgroup: true)

      %w[INT TERM].each do |sig|
        trap(sig) { signal_group(child, sig) }
      end

      _pid, status = Process.wait2(child)
      status.exitstatus || (status.termsig ? 128 + status.termsig : 1)
    rescue Errno::ENOENT
      raise Error, "command not found: #{command.first}"
    end

    def signal_group(child, sig)
      Process.kill(sig, -Process.getpgid(child))
    rescue StandardError
      nil
    end

    def child_env(port, url)
      {
        "PORT" => port.to_s,
        "HOST" => "127.0.0.1",
        "PORTLESS_URL" => url,
        # Let the app's own server-side TLS verification trust our CA.
        "SSL_CERT_FILE" => (File.exist?(State.ca_cert) ? State.ca_cert : nil)
      }.compact
    end

    # Explicit command wins; bare `portless-rb` falls back to the project's dev
    # runner (bin/dev, then bin/rails server).
    def resolved_command
      return @command unless @command.empty?
      return [ "bin/dev" ] if File.executable?("bin/dev")
      return [ "bin/rails", "server" ] if File.executable?("bin/rails")

      []
    end

    def announce(url, port)
      warn "portless-rb → #{url}  (backend :#{port})"
    end
  end
end
