# frozen_string_literal: true

require "rbconfig"

module Portless
  # Spawning the child command: /bin/sh -c with shell-escaped args (so shims
  # and scripts resolve, and a missing command is the shell's 127, not a Ruby
  # exception), node_modules/.bin prepended to PATH, its own process group,
  # INT/TERM/HUP forwarded to the tree with a 5s grace → TERM and 10s → KILL.
  # Mirrors portless's spawnCommand/augmentedPath.
  module RunSupport
    module_function

    COMMAND_SHUTDOWN_GRACE = 5.0
    COMMAND_SHUTDOWN_FORCE = 10.0
    POLL = 0.05
    FORWARDED_SIGNALS = %w[INT TERM HUP].freeze

    def shell_escape(arg) = "'#{arg.gsub("'", "'\\\\''")}'"

    def collect_bin_paths(cwd)
      dirs = []
      Auto.each_ancestor(cwd) do |dir|
        bin = File.join(dir, "node_modules", ".bin")
        dirs << bin if File.exist?(bin)
      end
      dirs
    end

    # PATH with node_modules/.bin dirs first and the running interpreter's
    # bin dir last (upstream appends node's dir).
    def augmented_path(env = ENV, cwd = Dir.pwd)
      base = env["PATH"] || env["Path"] || ""
      [ *collect_bin_paths(cwd), base, File.dirname(RbConfig.ruby) ].reject(&:empty?).join(File::PATH_SEPARATOR)
    end

    # Variables Bundler sets up; everything else in ENV (including what the CLI
    # itself sets, e.g. PORTLESS_LAN) passes through untouched.
    BUNDLER_ENV_KEYS = /\A(?:BUNDLE_\w+|BUNDLER_\w+|RUBYOPT|RUBYLIB|RUBYGEMS_GEMDEPS|GEM_HOME|GEM_PATH|MANPATH|PATH)\z/

    # ENV deltas that undo Bundler for the child (nil unsets). Plumbing: our
    # own bundle must not leak into the dev command.
    def unbundled_overrides
      return {} unless defined?(Bundler) && Bundler.respond_to?(:unbundled_env)

      target = Bundler.unbundled_env
      (ENV.keys | target.keys).grep(BUNDLER_ENV_KEYS).each_with_object({}) do |key, deltas|
        deltas[key] = target[key] if ENV[key] != target[key]
      end
    rescue StandardError
      {}
    end

    # CA env for a child under a TLS proxy: NODE_EXTRA_CA_CERTS (upstream; the
    # single-app run keeps a user's value, multi-app overrides it) and the
    # Ruby analogue SSL_CERT_FILE (combined bundle, CaBundle) under the same
    # conditions, never replacing a user's SSL_CERT_FILE.
    def ca_env(state_dir, tls, override_node_ca: false)
      ca_path = File.join(state_dir, "ca.pem")
      return {} unless tls && File.exist?(ca_path)

      env = {}
      env["NODE_EXTRA_CA_CERTS"] = ca_path if override_node_ca || !ENV["NODE_EXTRA_CA_CERTS"]
      bundle = !ENV["SSL_CERT_FILE"] && CaBundle.path
      env["SSL_CERT_FILE"] = bundle if bundle
      env
    end

    # Runs the command and returns the exit code the CLI should exit with.
    # env: overrides merged over ENV (nil unsets). Callbacks: on_spawn(pid),
    # on_exit(pid, code) (only on a natural exit), on_signal (an INT/TERM/HUP
    # arrived; runs in the trap handler), on_cleanup.
    def spawn_command(command_args, env: {}, on_spawn: nil, on_exit: nil, on_signal: nil, on_cleanup: nil, cwd: nil)
      child_env = unbundled_overrides.merge(env)
      merged_path_source = ENV.to_h.merge(child_env.compact)
      child_env["PATH"] = augmented_path(merged_path_source, cwd || Dir.pwd)

      reader, writer = IO.pipe
      previous = {}
      FORWARDED_SIGNALS.each do |sig|
        previous[sig] = trap(sig) do
          on_signal&.call
          writer.write_nonblock(sig[0])
        rescue StandardError
          nil
        end
      end

      script = command_args.map { |a| shell_escape(a) }.join(" ")
      spawn_opts = { pgroup: true }
      spawn_opts[:chdir] = cwd if cwd
      pid = Process.spawn(child_env, "/bin/sh", "-c", script, **spawn_opts)
      on_spawn&.call(pid)
      waiter = Thread.new { Process.wait2(pid).last }
      supervise(pid, waiter, reader, on_exit)
    ensure
      FORWARDED_SIGNALS.each { |sig| trap(sig, previous[sig] || "DEFAULT") } unless previous.nil?
      reader&.close
      writer&.close
      on_cleanup&.call
    end

    SIGNAL_NAMES = { "I" => "INT", "T" => "TERM", "H" => "HUP" }.freeze

    def supervise(pid, waiter, reader, on_exit)
      tracked = {}
      shutdown = nil
      started = nil
      grace_sent = force_sent = false
      loop do
        ready = IO.select([ reader ], nil, nil, POLL)
        if ready
          reader.read_nonblock(64, exception: false).to_s.each_char do |c|
            sig = SIGNAL_NAMES[c] or next
            ProcessGroup.track_process_tree(pid, tracked)
            if shutdown
              ProcessGroup.signal_tracked(tracked, sig)
            else
              shutdown = sig
              started = ProcessGroup.monotonic
              kill_tree(pid, sig)
            end
          end
        end

        if shutdown
          elapsed = ProcessGroup.monotonic - started
          if !grace_sent && elapsed >= COMMAND_SHUTDOWN_GRACE
            grace_sent = true
            ProcessGroup.track_process_tree(pid, tracked)
            ProcessGroup.signal_tracked(tracked, "TERM")
          end
          if !force_sent && elapsed >= COMMAND_SHUTDOWN_FORCE
            force_sent = true
            ProcessGroup.track_process_tree(pid, tracked)
            ProcessGroup.signal_tracked(tracked, "KILL")
          end
          if !waiter.alive? && !ProcessGroup.any_running?(tracked.reject { |p, _| p == pid })
            return 128 + (ProcessGroup::SIGNAL_CODES[shutdown] || 15)
          end
          next
        end

        next if waiter.alive?

        status = waiter.value
        if status.signaled?
          name = Signal.signame(status.termsig)
          return 128 + (ProcessGroup::SIGNAL_CODES[name] || 15)
        end
        code = status.exitstatus
        begin
          on_exit&.call(pid, code)
        rescue StandardError
          nil
        end
        return code || 1
      end
    end

    def kill_tree(pid, signal)
      Process.kill(signal, -pid)
    rescue StandardError
      begin
        Process.kill(signal, pid)
      rescue StandardError
        nil
      end
    end
  end
end
