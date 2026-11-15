# frozen_string_literal: true

require "open3"

module Portless
  # Zero-arg mode at a workspace root: every package with the target script
  # runs, proxied ones at `<pkg>.<project>.<tld>`. With a turbo.json, Turbo
  # runs the tasks and per-package env travels through the Turbo manifest;
  # otherwise each package is spawned directly with prefixed output.
  # Mirrors portless's handleDefaultMulti / runWithTurbo / runWithDirectSpawn.
  class Multi
    SIGKILL_TIMEOUT = 5.0

    App = Struct.new(:pkg, :name, :label, :command_args, :app_port, :proxied, keyword_init: true)

    def initialize(ws_root, global_script, extra_args)
      @ws_root = File.expand_path(ws_root)
      @global_script = global_script
      @extra_args = extra_args
    end

    def run
      loaded = Config.load_config(@ws_root)
      packages = Workspace.discover_workspace_packages(@ws_root)
      if packages.empty?
        warn Colors.red("Error: No workspace packages found.", io: $stderr)
        return 1
      end

      config_script = loaded&.config&.dig("script") || "dev"
      script_name = @global_script || config_script
      use_turbo = loaded&.config&.dig("turbo") != false && Turbo.turbo_config?(@ws_root)
      check_turbo_forwarding(script_name) if use_turbo && !@extra_args.empty? && Config.script?(script_name, @ws_root)

      project = project_name(loaded, packages)
      env_app_port = cli.app_port_from_env
      worktrees = {}
      worktree_for = lambda do |wt|
        style = wt&.dig("prefix") || "last-segment"
        worktrees[style] = Auto.detect_worktree_prefix(@ws_root, style) unless worktrees.key?(style)
        worktrees[style]
      end

      apps = packages.filter_map do |pkg|
        rel = Config.relative_path(@ws_root, pkg.dir).to_s
        root_override = loaded ? Config.resolve_app_config(loaded.config, loaded.config_dir, pkg.dir) : {}
        leaf = Config.load_config(pkg.dir)
        leaf_config = leaf ? Config.resolve_app_config(leaf.config, leaf.config_dir, pkg.dir) : {}
        override = root_override.compact.merge(leaf_config.compact)
        override["worktree"] = Config.merge_worktree_config(root_override["worktree"], leaf_config["worktree"])

        effective_script = @global_script || override["script"] || config_script
        script_value = pkg.scripts[effective_script]
        next unless script_value.is_a?(String) && !script_value.empty?

        raw = Config.split_command(script_value)
        next if raw.empty?

        pm = Config.detect_package_manager(pkg.dir)
        forwarded = use_turbo ? [] : cli.forward_script_extra_args(effective_script, pkg.dir, @extra_args)
        command_args = Config.script_run_command(pm, effective_script, pkg.dir, forwarded)
        proxied = override.key?("proxy") ? override["proxy"] : Config.server_command?(raw)

        if override["name"]
          name = cli.truncate_name(override["name"])
          label = override["name"]
        else
          pkg_label = pkg.name ? Auto.sanitize_for_hostname(pkg.name) : ""
          pkg_label = rel.tr("/", "-") if pkg_label.empty?
          name = pkg_label == project ? project : "#{pkg_label}.#{project}"
          label = pkg.scope ? "@#{pkg.scope}/#{pkg.name}" : (pkg.name || rel)
        end
        name = Auto.apply_worktree_prefix(name, worktree_for.(override["worktree"]),
                                          override.dig("worktree", "hostnameTemplate"))
        App.new(pkg: pkg, name: name, label: label, command_args: command_args,
                app_port: env_app_port || override["appPort"], proxied: proxied)
      end

      if apps.empty?
        warn Colors.yellow("No workspace packages have a \"#{script_name}\" script.", io: $stderr)
        return 1
      end

      apps.sort_by!(&:label)
      proxied_apps = apps.select(&:proxied)
      task_apps = apps.reject(&:proxied)
      if env_app_port && proxied_apps.length > 1
        raise UsageError.new(
          "PORTLESS_APP_PORT sets one port, but this run starts #{proxied_apps.length} apps.",
          [ "Set appPort for each app in portless.json, or unset PORTLESS_APP_PORT.",
            'Example: { "apps": { "packages/web": { "appPort": 4100 }, "packages/api": { "appPort": 4200 } } }' ]
        )
      end

      warn Colors.bold("\nrb-portless\n", io: $stderr)
      state = CLI.discover_state
      if proxied_apps.any?
        desired = Daemon.resolve_desired_state(false)
        result = Daemon.ensure_proxy_running(state.port, state.tls, desired)
        state = result[:started] ? CLI.state_struct(result[:state]) : CLI.discover_state
        check_hostname_collisions(proxied_apps, state.tlds)
        CLI.handle_trust if state.tls && !Trust.trusted?(state.dir)
      end

      if use_turbo
        run_with_turbo(state, script_name, proxied_apps)
      else
        run_with_direct_spawn(state, proxied_apps, task_apps)
      end
    end

    private

    def cli = @cli ||= CLI.new([])

    def check_turbo_forwarding(script_name)
      forwarding = Frameworks.resolve_turbo_root_forwarding(script_name, @ws_root)
      forwarded = @extra_args.join(" ")
      case forwarding[:kind]
      when "unsafe"
        hints = if forwarding[:turbo]
                  [ "  Change the root \"#{script_name}\" script to a single command, such as \"turbo #{script_name}\"." ]
                else
                  [ "  Run the command directly: rb-portless run <command> #{forwarded}",
                    "  Or change the root \"#{script_name}\" script to a single command." ]
                end
        raise UsageError.new("Cannot forward arguments through the \"#{script_name}\" root script. It has shell " \
                             "operators or a comment.", hints)
      when "too-deep"
        raise UsageError.new("Cannot forward arguments through the \"#{script_name}\" script. It runs through too " \
                             "many package scripts, or the scripts call each other in a loop.",
                             [ "Run the command directly: rb-portless run <command> #{forwarded}" ])
      end
    end

    def project_name(loaded, packages)
      return cli.truncate_name(loaded.config["name"]) if loaded&.config&.dig("name")

      counts = packages.filter_map(&:scope).tally
      common = counts.max_by { |_, c| c }&.first
      sanitized = common ? Auto.sanitize_for_hostname(common) : ""
      sanitized.empty? ? Auto.infer_project_name(@ws_root).name : sanitized
    end

    def check_hostname_collisions(apps, tlds)
      seen = {}
      where = ->(app) { "\"#{app.label}\" (#{Config.relative_path(@ws_root, app.pkg.dir).then { |r| r.to_s.empty? ? '.' : r }})" }
      apps.each do |app|
        Runner.build_hostnames(app.name, tlds).each do |h|
          if (existing = seen[h])
            raise Error, "Duplicate hostname \"#{h}\" for #{where.(existing)} and #{where.(app)}. Set unique \"name\" " \
                         "overrides; if using worktree.hostnameTemplate, include {name}."
          end
          seen[h] = app
        end
      end
    end

    def app_env(state, port, url)
      env = { "PORT" => port.to_s, "HOST" => "127.0.0.1", "PORTLESS_URL" => url,
              "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => Runner.format_vite_allowed_hosts(state.tlds) }
      ca = File.join(state.dir, "ca.pem")
      env["NODE_EXTRA_CA_CERTS"] = ca if state.tls && File.exist?(ca)
      env
    end

    def print_urls(app_urls)
      unless app_urls.empty?
        width = app_urls.map { |l, _| l.length }.max
        app_urls.each { |label, url| warn "  #{label.ljust(width)}  #{Colors.dim(url, io: $stderr)}" }
      end
      warn ""
    end

    def new_store(dir) = RouteStore.new(dir, on_warning: ->(msg) { warn Colors.yellow(msg, io: $stderr) })

    def run_with_turbo(state, script_name, proxied_apps)
      store = new_store(state.dir)
      manifest = {}
      routes = []
      app_urls = []
      proxied_apps.each do |app|
        if app.command_args[0] == "rb-portless"
          app_urls << [ app.label, "(managed by rb-portless)" ]
          next
        end
        port = app.app_port || FreePort.find
        hostnames = Runner.build_hostnames(app.name, state.tlds)
        url = Utils.format_url(hostnames.first, state.port, state.tls)
        app_urls << [ app.label, url ]
        Runner.add_routes(store, hostnames, port, Process.pid)
        routes << hostnames
        manifest[app.pkg.dir] = app_env(state, port, url)
      end
      Turbo.ensure_env_loader
      Turbo.write_manifest(manifest)
      print_urls(app_urls)

      pm = Config.detect_package_manager(@ws_root)
      root_script = Config.script?(script_name, @ws_root)
      forwarding = root_script ? Frameworks.resolve_turbo_root_forwarding(script_name, @ws_root) : nil
      separators = root_script ? (forwarding[:kind] == "forward" ? forwarding[:separators] : 0) : 1
      pass = !@extra_args.empty? && separators.positive? ? Array.new(separators, "--") + @extra_args : @extra_args
      turbo_args = root_script ? Config.script_run_command(pm, script_name, @ws_root, pass)
                               : Config.package_manager_exec(pm, [ "turbo", "run", script_name, *pass ])

      env = RunSupport.unbundled_overrides.merge("NODE_OPTIONS" => Turbo.build_node_options)
      pid = Process.spawn(env, *turbo_args, chdir: @ws_root, pgroup: true)
      code = wait_children([ pid ]) { cleanup_routes(store, routes) }.values.first
      cleanup_routes(store, routes)
      Turbo.remove_manifest
      code.nil? || code.zero? ? 0 : code
    end

    def cleanup_routes(store, routes) = routes.each { |h| Runner.remove_routes(store, h, Process.pid) }

    def run_with_direct_spawn(state, proxied_apps, task_apps)
      store = new_store(state.dir)
      children = {}
      routes = []
      app_urls = []
      proxied_apps.each do |app|
        env = RunSupport.unbundled_overrides
        env["PATH"] = RunSupport.augmented_path(ENV, app.pkg.dir)
        if app.command_args[0] == "rb-portless"
          app_urls << [ app.label, "(managed by rb-portless)" ]
        else
          port = app.app_port || FreePort.find
          hostnames = Runner.build_hostnames(app.name, state.tlds)
          url = Utils.format_url(hostnames.first, state.port, state.tls)
          Runner.add_routes(store, hostnames, port, Process.pid)
          routes << hostnames
          env.merge!(app_env(state, port, url))
          app_urls << [ app.label, url ]
        end
        children[spawn_prefixed(app, env)] = app
      end
      task_apps.each do |app|
        env = RunSupport.unbundled_overrides.merge("PATH" => RunSupport.augmented_path(ENV, app.pkg.dir))
        children[spawn_prefixed(app, env)] = app
      end
      print_urls(app_urls)

      codes = wait_children(children.keys) { nil }
      cleanup_routes(store, routes)
      failed = codes.reject { |_, c| c.nil? || c.zero? }
      return 0 if failed.empty?

      warn Colors.red("\n#{failed.length} app#{failed.length == 1 ? '' : 's'} exited with errors: " \
                      "#{failed.map { |pid, c| "#{children[pid].label} (#{c})" }.join(', ')}", io: $stderr)
      1
    end

    def spawn_prefixed(app, env)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(env, *app.command_args, chdir: app.pkg.dir, in: File::NULL, out: out_w, err: err_w,
                                                  pgroup: true)
      out_w.close
      err_w.close
      prefix = "[#{app.name}]"
      [ [ out_r, $stdout ], [ err_r, $stderr ] ].each do |io, target|
        Thread.new do
          io.each_line { |line| target.write("#{prefix} #{line.chomp}\n") }
        rescue IOError
          nil
        end
      end
      @labels ||= {}
      @labels[pid] = app.name
      pid
    end

    # Waits for all children; INT/TERM/HUP → TERM the trees, KILL after 5s.
    # => {pid => exit code (nil when signalled)}
    def wait_children(pids)
      codes = {}
      reader, writer = IO.pipe
      previous = %w[INT TERM HUP].to_h { |s| [ s, trap(s) { writer.write_nonblock("x") rescue nil } ] }
      waiters = pids.to_h { |pid| [ pid, Thread.new { Process.wait2(pid).last } ] }
      deadline = nil
      until waiters.values.none?(&:alive?)
        if IO.select([ reader ], nil, nil, 0.05) && deadline.nil?
          reader.read_nonblock(64, exception: false)
          yield
          waiters.each_key { |pid| RunSupport.kill_tree(pid, "TERM") }
          deadline = ProcessGroup.monotonic + SIGKILL_TIMEOUT
        end
        if deadline && ProcessGroup.monotonic > deadline
          waiters.each { |pid, t| RunSupport.kill_tree(pid, "KILL") if t.alive? }
          deadline = Float::INFINITY
        end
      end
      waiters.each do |pid, t|
        status = t.value
        app = @labels&.[](pid)
        if status.exitstatus && status.exitstatus != 0 && app
          warn Colors.red("[#{app}] exited with code #{status.exitstatus}", io: $stderr)
        elsif status.signaled? && app
          warn Colors.yellow("[#{app}] killed by SIG#{Signal.signame(status.termsig)}", io: $stderr)
        end
        codes[pid] = status.exitstatus
      end
      codes
    ensure
      previous&.each { |s, h| trap(s, h || "DEFAULT") }
      reader&.close
      writer&.close
    end
  end
end
