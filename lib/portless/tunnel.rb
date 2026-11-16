# frozen_string_literal: true

require "uri"
require "open3"
require "timeout"

module Portless
  # Public tunnels that run a provider CLI (ngrok, cloudflared) pointed at the
  # app's backend port: check the tool before the proxy starts, spawn it, read
  # the public URL from its output (30 s timeout), and hand back a handle whose
  # pid the runner records on the route so prune/clean can reap orphans.
  # Mirrors portless's tunnel.ts (+ PROCESS_TUNNELS / stopRecordedTunnels /
  # printTunnelHint from cli.ts).
  module Tunnel
    module_function

    START_TIMEOUT = 30
    COMMAND_TIMEOUT = 10
    OUTPUT_BUFFER_LIMIT = 16_384

    # A provider: binary, version_args, build_args(port, opts), extract_url,
    # format_output_error, not_found, timeout.
    Provider = Struct.new(:binary, :version_args, :build_args, :extract_url, :format_output_error,
                          :not_found, :timeout, keyword_init: true)

    # The per-route tunnel table (cli.ts PROCESS_TUNNELS).
    PROCESS_TUNNELS = [
      { name: :ngrok, label: "ngrok", binary: "ngrok", env: "PORTLESS_NGROK", via: "ngrok",
        install: "https://ngrok.com/download", url_field: :ngrok_url, pid_field: :ngrok_pid },
      { name: :cloudflare, label: "Cloudflare", binary: "cloudflared", env: "PORTLESS_CLOUDFLARE",
        via: "Cloudflare Tunnel", install: "https://developers.cloudflare.com/tunnel/downloads/",
        url_field: :cloudflare_url, pid_field: :cloudflare_pid }
    ].freeze

    def normalize_space(value) = value.to_s.strip.gsub(/\s+/, " ")

    def ngrok_output_error(output)
      details = normalize_space(output)
      lower = details.downcase
      if lower.include?("authtoken") || lower.include?("authentication") || lower.include?("not logged in")
        return Error.new("ngrok could not start because authentication is not configured. Run " \
                         "`ngrok config add-authtoken <token>`, then run rb-portless again.")
      end

      Error.new("Failed to start ngrok tunnel: #{details.empty? ? 'ngrok exited before printing a public URL' : details}")
    end

    def clean_url(value) = value.sub(/[),.]+\z/, "")

    # tunnel.ts extractNgrokUrl.
    def extract_ngrok_url(output)
      output.to_enum(:scan, %r{https://[^\s"'<>]+}).each do
        match = Regexp.last_match
        raw = match[0]
        index = match.begin(0)
        before = output[[ 0, index - 80 ].max...index].downcase
        looks = before.include?("forwarding") || before.include?("url=") || before.include?('"url"') ||
                before.include?("started tunnel")
        next unless looks

        candidate = clean_url(raw)
        begin
          uri = URI.parse(candidate)
          host = uri.host.to_s
          next if host.empty? || host == "ngrok.com" || host.end_with?(".ngrok.com")

          url = uri.to_s
          url = "#{url}/" if uri.path.to_s.empty?
          return url.sub(%r{/\z}, "")
        rescue URI::InvalidURIError
          next
        end
      end
      nil
    end

    def build_ngrok_args(local_port, host_header = "rewrite")
      [ "http", "--log=stdout", "--log-format=logfmt", "--host-header=#{host_header}",
        "http://127.0.0.1:#{local_port}" ]
    end

    def ngrok
      Provider.new(
        binary: "ngrok", version_args: [ "version" ],
        build_args: ->(port, opts) { build_ngrok_args(port, opts[:host_header] || "rewrite") },
        extract_url: method(:extract_ngrok_url), format_output_error: method(:ngrok_output_error),
        not_found: "ngrok CLI not found. Install ngrok (https://ngrok.com/download) and ensure `ngrok` is on PATH.",
        timeout: "Timed out waiting for ngrok to print a public URL. Check that ngrok is authenticated and can connect."
      )
    end

    def provider_for(name, **opts)
      case name.to_sym
      when :ngrok then ngrok
      when :cloudflare, :cloudflared then Cloudflare.provider(**opts)
      else raise ArgumentError, "unknown tunnel provider #{name}"
      end
    end

    def tunnel_for(name) = PROCESS_TUNNELS.find { |t| t[:name] == name.to_sym || t[:binary] == name.to_s }

    def format_spawn_error(provider, error)
      return Error.new(provider.not_found) if error.is_a?(Errno::ENOENT)

      Error.new("Failed to start #{provider.binary}: #{error.message}")
    end

    # Run `<binary> <version_args>` → {status:, stdout:, stderr:, error:}
    def default_runner(binary, args)
      stdout, stderr, status = Timeout.timeout(COMMAND_TIMEOUT) { Open3.capture3(binary, *args) }
      { status: status.exitstatus, stdout: stdout, stderr: stderr }
    rescue Timeout::Error => e
      { status: nil, stdout: "", stderr: "", error: e }
    rescue SystemCallError => e
      { status: nil, stdout: "", stderr: "", error: e }
    end

    # tunnel.ts ensureTunnelAvailable — raises Portless::Error.
    def ensure_available(provider, runner = nil)
      runner ||= ->(args) { default_runner(provider.binary, args) }
      result = runner.call(provider.version_args)
      raise format_spawn_error(provider, result[:error]) if result[:error]
      return if result[:status].zero?

      details = normalize_space(result[:stderr].to_s.empty? ? result[:stdout] : result[:stderr])
      raise Error, "Failed to check #{provider.binary} version: " \
                   "#{details.empty? ? "unknown #{provider.binary} error" : details}"
    end

    # Contract entry point: verify the provider CLI before the proxy starts.
    def check!(name, runner = nil) = ensure_available(provider_for(name), runner)

    # The default tunnel child: the provider CLI with stdout and stderr piped.
    # A spawner may return any object with the same shape (pid, stdout,
    # stderr, kill(signal), wait → [code, signal]). tunnel.ts TunnelChildProcess.
    class ChildProcess
      attr_reader :pid, :stdout, :stderr

      def initialize(binary, args)
        @stdout, out_w = IO.pipe
        @stderr, err_w = IO.pipe
        @pid = Process.spawn(binary, *args, in: File::NULL, out: out_w, err: err_w)
      ensure
        out_w&.close
        err_w&.close
      end

      def kill(signal)
        Process.kill(signal.to_s.delete_prefix("SIG"), @pid)
        true
      end

      def wait
        _, status = Process.wait2(@pid)
        [ status.exitstatus, status.termsig && "SIG#{Signal.signame(status.termsig)}" ]
      end
    end

    # A running tunnel process.
    class Handle
      attr_accessor :url
      attr_reader :child

      def initialize(url, child)
        @url = url
        @child = child
        @exit_callbacks = []
        @exit_status = nil
        @mutex = Mutex.new
      end

      def pid = @child.pid

      def on_exit(&block)
        status = @mutex.synchronize do
          @exit_callbacks << block unless @exit_status
          @exit_status
        end
        block.call(*status) if status
        self
      end

      def exited(code, signal)
        callbacks = @mutex.synchronize do
          @exit_status = [ code, signal ]
          @exit_callbacks.dup
        end
        callbacks.each { |cb| cb.call(code, signal) }
      end

      def exited? = !@exit_status.nil?

      def stop
        Tunnel.stop_ngrok_process(@child) unless exited?
      end
    end

    # Spawn the provider and wait for its public URL. tunnel.ts startTunnel.
    # opts: host_header:, timeout: (seconds), spawner: ->(args) { child }.
    # Raises Portless::Error. A block is registered as the exit callback.
    def start_tunnel(provider, local_port, timeout: START_TIMEOUT, spawner: nil, **opts, &on_exit)
      args = provider.build_args.call(local_port, opts)
      begin
        child = (spawner || ->(a) { ChildProcess.new(provider.binary, a) }).call(args)
      rescue SystemCallError => e
        raise format_spawn_error(provider, e)
      end

      queue = Queue.new
      output = +""
      lock = Mutex.new
      started = false
      handle = Handle.new(nil, child)
      append_output = lambda do |chunk|
        lock.synchronize do
          next if started

          output << chunk
          output = output[-OUTPUT_BUFFER_LIMIT..] if output.bytesize > OUTPUT_BUFFER_LIMIT
          url = provider.extract_url.call(output)
          if url
            started = true
            queue << [ :url, url ]
          end
        end
      end
      readers = [ child.stdout, child.stderr ].compact.map do |io|
        Thread.new do
          loop { append_output.call(io.readpartial(4096)) }
        rescue EOFError, IOError
          nil
        end
      end
      Thread.new do
        code, signal = child.wait
        readers.each { |r| r.join(1) }
        if lock.synchronize { started }
          handle.exited(code, signal)
        else
          queue << [ :exit, code, signal ]
        end
      rescue StandardError
        queue << [ :exit, nil, nil ]
      end

      event = queue.pop(timeout: timeout)
      unless event
        begin
          child.kill("SIGTERM")
        rescue StandardError
          nil
        end
        raise Error, provider.timeout
      end

      case event.first
      when :url
        handle.url = event[1]
        handle.on_exit(&on_exit) if on_exit
        handle
      else
        _, code, signal = event
        suffix = if signal then " (signal #{signal})"
        elsif code then " (exit #{code})"
        else ""
        end
        error = provider.format_output_error.call(output)
        raise Error, "#{error.message}#{suffix}"
      end
    end

    # tunnel.ts stopNgrokProcess.
    def stop_ngrok_process(child)
      return unless child

      child.kill("SIGTERM")
    rescue StandardError
      nil
    end

    # Contract entry point. → Handle (#url, #pid, #stop, #on_exit)
    def start(name, app_port:, host:, state_dir: State.dir, timeout: START_TIMEOUT, spawner: nil, &on_exit)
      case name.to_sym
      when :ngrok
        start_tunnel(ngrok, app_port, host_header: host, timeout: timeout, spawner: spawner, &on_exit)
      else
        Cloudflare.start(app_port, host_header: host, config_path: File.join(state_dir, "cloudflared.yml"),
                                   timeout: timeout, spawner: spawner, &on_exit)
      end
    end

    def start_ngrok(local_port, **opts, &on_exit) = start_tunnel(ngrok, local_port, **opts, &on_exit)

    def ensure_ngrok_available(runner = nil) = ensure_available(ngrok, runner)

    def stop_pid(pid)
      return unless pid

      Process.kill("TERM", pid)
    rescue StandardError
      nil
    end

    # Stop the tunnel processes recorded on a route; with verify, skip pids not
    # running the tunnel binary. → the PROCESS_TUNNELS entries stopped.
    # cli.ts stopRecordedTunnels.
    def stop_recorded(route, verify: false)
      PROCESS_TUNNELS.select do |t|
        pid = route_field(route, t[:pid_field])
        next false if pid.nil? || pid.to_i <= 0
        next false if verify && PortOwner.command(pid.to_i) != t[:binary]

        stop_pid(pid.to_i)
        true
      end
    end

    def route_field(route, field)
      return route[field] || route[field.to_s] if route.is_a?(Hash)

      route.respond_to?(field) ? route.public_send(field) : nil
    end

    # Print the install/auth hint matching a tunnel error. cli.ts printTunnelHint.
    def print_hint(tunnel, message)
      tunnel = tunnel_for(tunnel) unless tunnel.is_a?(Hash)
      if message.include?("#{tunnel[:binary]} CLI not found")
        warn Colors.blue("Install #{tunnel[:binary]}: #{tunnel[:install]}", io: $stderr)
      elsif tunnel[:binary] == "ngrok" && message.include?("authentication is not configured")
        warn Colors.blue("Configure ngrok authentication:", io: $stderr)
        warn Colors.cyan("  ngrok config add-authtoken <token>", io: $stderr)
      end
    end
  end
end
