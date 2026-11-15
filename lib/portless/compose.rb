# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"

module Portless
  # Docker Compose support. Mirrors portless's compose.ts (pure planning, the
  # module functions) and the compose section of cli.ts (process wiring,
  # Compose::Command).
  #
  # The approach: resolve the project with `docker compose config --format json`
  # (compose does interpolation, `extends`, `include`, and multi-file merges),
  # move each published HTTP port to a fixed loopback port kept per project,
  # run compose against the resolved model, then read the published ports back
  # from `docker compose ps` and register them as portless routes.
  module Compose
    module_function

    # Compose global flags that take a value.
    VALUE_FLAGS = %w[
      -f --file -p --project-name --profile --env-file --project-directory --workdir --ansi --progress --parallel
    ].freeze

    BOOLEAN_FLAGS = %w[--help -h --version -v --dry-run --verbose --no-ansi --compatibility --all-resources].freeze

    # Global flags portless replaces when it runs compose on the resolved model.
    REPLACED_FLAGS = %w[-f --file -p --project-name --project-directory --workdir].freeze

    # Container ports of common non-HTTP services. They keep their published
    # port so existing connection strings (DATABASE_URL=...:5432) keep working.
    NON_HTTP_PORTS = [
      1433, # SQL Server
      1521, # Oracle
      2181, # ZooKeeper
      3306, # MySQL, MariaDB
      4222, # NATS
      5432, # PostgreSQL
      5672, # RabbitMQ
      6379, # Redis, Valkey
      9042, # Cassandra
      9092, # Kafka
      11211, # Memcached
      26257, # CockroachDB
      27017 # MongoDB
    ].freeze

    LABEL_ENABLE = "portless.enable"
    LABEL_NAME = "portless.name"
    LABEL_PORTS = "portless.ports"

    VITE_ALLOWED_HOSTS_ENV = "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS"

    # globals: global compose flags, in order. dock_args: every argument except
    # the wrapper's own `--`.
    ComposeArgs = Struct.new(:globals, :subcommand, :rest, :docker_args, keyword_init: true)
    # One decoded global compose flag and the raw arguments it spans.
    ComposeGlobal = Struct.new(:flag, :value, :raw, :error, keyword_init: true)
    # hostnames: one per configured TLD, the first is primary.
    ComposeRoute = Struct.new(:service, :target, :hostnames, :url, keyword_init: true)
    # dropped: the binding was removed from the model instead of kept.
    KeptPort = Struct.new(:service, :target, :published, :reason, :dropped, keyword_init: true)
    # project: compose project name as compose resolved it; model: the resolved
    # model to run, with routed ports moved to loopback ports.
    ComposePlan = Struct.new(:project, :model, :routes, :kept, keyword_init: true)
    # projects: compose project names seen, in order. ports: host ports
    # published by running containers, keyed by "service:target".
    ComposeContainers = Struct.new(:projects, :ports, keyword_init: true)

    TRUE_VALUES = %w[1 t T TRUE true True].freeze
    FALSE_VALUES = %w[0 f F FALSE false False].freeze

    # Whether `value` is a boolean literal Docker's flag parser accepts.
    def boolean_value?(value) = TRUE_VALUES.include?(value) || FALSE_VALUES.include?(value)

    def boolean_true?(value) = TRUE_VALUES.include?(value)

    # Read one global compose flag at `index`, keeping the raw arguments it
    # spans. A value is attached with `--flag=value`, `-f=value`, or
    # `-fvalue`, or follows as the next argument.
    def read_compose_global(args, index)
      arg = args[index]
      long = arg.start_with?("--")
      eq = long ? arg.index("=") : nil
      flag = long ? (eq ? arg[0...eq] : arg) : arg[0, 2]
      tail = long ? (eq ? arg[eq..] : nil) : arg[2..].then { |t| t.nil? || t.empty? ? nil : t }
      attached = tail&.sub(/\A=/, "")

      if VALUE_FLAGS.include?(flag)
        value = attached.nil? ? args[index + 1] : attached
        raw = attached.nil? && !value.nil? ? [ arg, value ] : [ arg ]
        return ComposeGlobal.new(flag: flag, value: value, raw: raw) if value && !value.empty?

        return ComposeGlobal.new(flag: flag, raw: raw, error: "#{flag} requires a value.")
      end
      if BOOLEAN_FLAGS.include?(flag) && (tail.nil? || tail.start_with?("="))
        return ComposeGlobal.new(flag: flag, value: attached, raw: [ arg ]) if attached.nil? || boolean_value?(attached)

        return ComposeGlobal.new(flag: flag, value: attached, raw: [ arg ], error: "#{flag} takes true or false.")
      end
      name = long ? flag : arg
      ComposeGlobal.new(flag: name, raw: [ arg ], error: "Unknown flag \"#{name}\" for rb-portless compose.")
    end

    # Decode a run of global compose flags in order.
    def decode_compose_globals(globals)
      decoded = []
      i = 0
      while i < globals.length
        global = read_compose_global(globals, i)
        decoded << global
        i += global.raw.length
      end
      decoded
    end

    # Split `compose` arguments into global flags, subcommand, and the rest. A
    # `--` ends the wrapper's own flags, so the next argument is the subcommand.
    def split_compose_args(args)
      globals = []
      terminated = false
      i = 0
      while i < args.length
        arg = args[i]
        if arg == "--"
          terminated = true
          i += 1
          break
        end
        break unless arg.start_with?("-")

        global = read_compose_global(args, i)
        globals.concat(global.raw)
        i += global.raw.length
      end
      ComposeArgs.new(globals: globals, subcommand: args[i], rest: args[(i + 1)..] || [],
                      docker_args: terminated ? globals + (args[i..] || []) : args.dup)
    end

    # The first problem with a compose invocation's own global flags, or nil
    # when they all parse. Checked before any docker work, so a typo is a
    # usage error (exit 2) instead of a docker failure (exit 1).
    def compose_global_error(globals)
      decode_compose_globals(globals).each { |g| return g.error if g.error }
      nil
    end

    # Whether a named boolean global flag is set to true.
    def global_flag_set?(globals, names)
      decode_compose_globals(globals).any? do |g|
        names.include?(g.flag) && (g.value.nil? || boolean_true?(g.value))
      end
    end

    # Values of a global flag, in order. Handles `--flag=value` and `-fvalue`.
    def read_global(globals, names)
      decode_compose_globals(globals).filter_map { |g| g.value if !g.value.nil? && names.include?(g.flag) }
    end

    # Whether the compose file is read from stdin (`-f -`).
    def reads_compose_from_stdin?(globals) = read_global(globals, %w[-f --file]).include?("-")

    # Project name passed with -p or --project-name, if any.
    def explicit_project(globals) = read_global(globals, %w[-p --project-name]).last

    # Arguments that run `docker compose up` on the resolved model. The
    # project directory stays where compose would put it (the explicit flag,
    # else the first compose file's directory from -f or COMPOSE_FILE, else
    # cwd), so `.env` settings such as COMPOSE_PROFILES still apply.
    def build_up_args(globals:, rest:, project:, model_path:, cwd:, compose_file_env: nil, path_separator: nil)
      first_file = read_global(globals, %w[-f --file]).first ||
                   compose_file_env&.split(path_separator || File::PATH_SEPARATOR, -1)&.first
      project_dir = read_global(globals, [ "--project-directory" ]).last ||
                    read_global(globals, [ "--workdir" ]).last ||
                    (first_file && !first_file.empty? && first_file != "-" ? File.dirname(File.expand_path(first_file, cwd)) : cwd)
      kept = decode_compose_globals(globals).reject { |g| REPLACED_FLAGS.include?(g.flag) }.flat_map(&:raw)
      [ "-p", project, "--project-directory", project_dir, "-f", model_path, *kept, "up", *rest ]
    end

    # Whether `up` arguments leave compose running in the background.
    def detached_up?(rest) = rest.any? { |a| %w[-d --detach --wait --wait=true].include?(a) }

    # Turn a compose project or service name into a DNS label.
    def to_label(name)
      Auto.truncate_label(name.downcase.gsub(/[^a-z0-9-]+/, "-").gsub(/\A-+|-+\z/, ""))
    end

    # Suffix shared by every route of a project, e.g. "shop" for "api.shop".
    def project_label(project) = to_label(project)

    # JavaScript Number() for a label value: decimal, exponent, or 0x/0o/0b.
    def js_number(raw)
      str = raw.strip
      return 0 if str.empty?
      return Integer(str, exception: false) || Float::NAN if str.match?(/\A0[xob]\h+\z/i)
      return Float(str) if str.match?(/\A[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?\z/i)

      Float::NAN
    end

    # Per-service settings from labels. Labels survive `config --format
    # json`; `x-` keys in a service do not.
    def read_service_settings(service, svc)
      labels = svc["labels"] || {}
      enable = labels[LABEL_ENABLE]&.strip&.downcase
      settings = { enabled: enable != "false" && enable != "0" }

      name = labels[LABEL_NAME]&.strip
      if name && !name.empty?
        label = to_label(name)
        raise Error, "#{service}: #{LABEL_NAME} \"#{name}\" is not a valid hostname label." if label.empty?

        settings[:name] = label
      end

      ports = labels[LABEL_PORTS]&.strip
      if ports && !ports.empty?
        settings[:ports] = ports.split(",", -1).map do |raw|
          port = js_number(raw)
          unless port.is_a?(Numeric) && port.finite? && port == port.to_i && port >= 1 && port <= 65_535
            raise Error, "#{service}: #{LABEL_PORTS} has an invalid port \"#{raw.strip}\"."
          end

          port.to_i
        end
      end
      settings
    end

    # Plan a resolved compose model. Every published TCP port moves to
    # 127.0.0.1, on the port from `port_for` (ephemeral without one), and gets
    # a route `<service>.<project>`. A service with several routed ports gets
    # `<service>.<project>` for the first and `<port>.<service>.<project>` for
    # each of them. Routed services get the Vite allowed-hosts variable so a
    # dev server in a container accepts its hostname.
    #
    # hostnames_for: expand a route name like "api.shop" into its hostnames
    # (raises on invalid names). port_for: fixed host port for a routed
    # container port; a fixed port survives restarts, so routes never drift.
    def plan_compose(model, hostnames_for:, url_for:, vite_allowed_hosts:, port_for: nil)
      project = project_label(model["name"])
      routes = []
      kept = []
      services = {}
      seen = {}

      (model["services"] || {}).each do |service, svc|
        ports = svc["ports"] || []
        keep_all = lambda do |reason|
          ports.each { |p| kept << KeptPort.new(service: service, target: p["target"], published: p["published"], reason: reason) }
          services[service] = svc
        end
        if ports.empty?
          services[service] = svc
          next
        end
        if svc["network_mode"] == "host"
          keep_all.("host network")
          next
        end
        settings = read_service_settings(service, svc)
        unless settings[:enabled]
          keep_all.("#{LABEL_ENABLE}=false")
          next
        end
        if settings[:ports]
          missing = settings[:ports].reject { |p| ports.any? { |q| q["target"] == p } }
          unless missing.empty?
            raise Error, "#{service}: #{LABEL_PORTS} lists #{missing.join(', ')}, but the service does not publish " \
                         "#{missing.length > 1 ? 'them' : 'it'}."
          end
        end

        routed_targets = []
        next_ports = []
        ports.each do |p|
          keep = lambda do |reason|
            kept << KeptPort.new(service: service, target: p["target"], published: p["published"], reason: reason)
            next_ports << p
          end
          protocol = p["protocol"] || "tcp"
          if protocol != "tcp"
            keep.(p["protocol"] || "udp")
          elsif settings[:ports] && !settings[:ports].include?(p["target"])
            keep.("not in #{LABEL_PORTS}")
          elsif !settings[:ports] && NON_HTTP_PORTS.include?(p["target"])
            keep.("not HTTP")
          elsif routed_targets.include?(p["target"])
            # One loopback binding serves the route. Extra bindings of the same
            # target (0.0.0.0 and :: on one port, or a second host port) are
            # dropped so their fixed host port cannot collide with another project.
            kept << KeptPort.new(service: service, target: p["target"], published: p["published"],
                                 reason: "the container port is already routed", dropped: true)
          else
            routed_targets << p["target"]
            port = port_for&.call(service, p["target"])
            moved = p.except("published")
            moved["host_ip"] = "127.0.0.1"
            moved["published"] = port.to_s unless port.nil?
            next_ports << moved
          end
        end

        label = settings[:name] || to_label(service)
        routed_targets.each_with_index do |target, index|
          subs = routed_targets.length > 1 ? [ "#{target}.#{label}" ] : []
          subs.unshift(label) if index.zero?
          subs.each do |sub|
            name = "#{sub}.#{project}"
            owner = seen[name]
            if owner && owner != service
              raise Error, "Services \"#{owner}\" and \"#{service}\" both map to #{name}. Rename one of them."
            end

            seen[name] = service
            hostnames = hostnames_for.call(name)
            routes << ComposeRoute.new(service: service, target: target, hostnames: hostnames,
                                       url: url_for.call(hostnames.first))
          end
        end

        environment = (svc["environment"] || {}).dup
        if !routed_targets.empty? && !environment.key?(VITE_ALLOWED_HOSTS_ENV)
          environment[VITE_ALLOWED_HOSTS_ENV] = vite_allowed_hosts
        end
        services[service] = svc.merge("ports" => next_ports, "environment" => environment)
      end

      ComposePlan.new(project: model["name"], model: model.merge("services" => services), routes: routes, kept: kept)
    end

    # Parse `docker compose ps --format json`. Compose v2.21+ prints one JSON
    # object per line; older versions print a single array.
    def parse_containers(output)
      result = ComposeContainers.new(projects: [], ports: {})
      trimmed = output.strip
      return result if trimmed.empty?

      rows = if trimmed.start_with?("[")
               JSON.parse(trimmed)
      else
               trimmed.split("\n").reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
      end
      rows.each do |r|
        project = r["Project"]
        result.projects << project if project && !project.empty? && !result.projects.include?(project)
        next if r["Service"].nil? || r["Service"].empty? || (r["State"] && !r["State"].empty? && r["State"] != "running")

        (r["Publishers"] || []).each do |p|
          published = p["PublishedPort"]
          target = p["TargetPort"]
          next if published.nil? || published.zero? || target.nil? || target.zero? || (p["Protocol"] || "tcp") != "tcp"

          key = "#{r['Service']}:#{target}"
          result.ports[key] = published unless result.ports.key?(key)
        end
      end
      result
    end

    # Host port of a route, or nil while its container is not running.
    def route_port(route, containers) = containers.ports["#{route.service}:#{route.target}"]

    # Aliases to remove after `docker compose down`: the project's aliases
    # whose port no longer belongs to a running container. Routes of services
    # that stay up (unselected services, profiles that were not enabled) are kept.
    def stale_aliases(aliases, project, tlds, containers)
      suffixes = tlds.map { |tld| ".#{project_label(project)}.#{tld}" }
      live = containers.ports.values
      aliases.select { |a| suffixes.any? { |s| a.hostname.end_with?(s) } && !live.include?(a.port) }.map(&:hostname)
    end

    # Fixed host ports for routed container ports, keyed like "service:target".
    # A stored port is reused while it is ours or free; new ports skip ports
    # that other projects saved. `ours`: ports this project's running
    # containers publish. `reserved`: ports saved by other projects.
    def allocate_ports(keys, stored, min:, max:, ours:, reserved:, free:, random: -> { rand })
      ports = {}
      taken = []
      size = max - min + 1
      keys.each do |key|
        previous = stored[key]
        if !previous.nil? && !taken.include?(previous) && !reserved.include?(previous) &&
           (ours.include?(previous) || free.call(previous))
          ports[key] = previous
          taken << previous
          next
        end
        start = (random.call * size).floor
        port = nil
        size.times do |i|
          candidate = min + ((start + i) % size)
          next if taken.include?(candidate) || reserved.include?(candidate)

          if free.call(candidate)
            port = candidate
            break
          end
        end
        raise Error, "No free port found in range #{min}-#{max}." if port.nil?

        ports[key] = port
        taken << port
      end
      ports
    end

    # The `compose` command: process wiring from cli.ts (handleCompose and
    # friends). #run returns the exit code.
    class Command
      include Help

      # Host ports for compose routes. Separate from the 4000-4999 range of `run`.
      MIN_PORT = 14_000
      MAX_PORT = 14_999

      def initialize(args, err: $stderr)
        @args = args
        @err = err
      end

      def run
        split = Compose.split_compose_args(@args)
        globals = split.globals
        subcommand = split.subcommand
        rest = split.rest
        child_help = rest.include?("--help") || rest.include?("-h")
        global_help = Compose.global_flag_set?(globals, %w[--help -h])

        if subcommand.nil?
          assert_compose_globals(globals) unless global_help
          return print_compose_help
        end

        return spawn_docker_compose(split.docker_args).value if Portless.skip_proxy?

        assert_compose_globals(globals) unless global_help

        if global_help || child_help || (subcommand != "up" && subcommand != "down")
          return spawn_docker_compose(split.docker_args).value
        end

        begin
          # stdin can be read once; keep it for every compose call that needs the file.
          input = Compose.reads_compose_from_stdin?(globals) ? $stdin.read : nil
          return compose_down(split.docker_args, globals, input) if subcommand == "down"

          # Include every profile so `up <service>` can start a service from
          # an inactive profile; compose still applies the user's --profile
          # flags at up.
          config = docker_compose([ *globals, "--profile", "*", "config", "--format", "json" ], input)
          unless config[:status].zero?
            @err.write(config[:stderr])
            raise Error, "docker compose config failed."
          end
          compose_up(JSON.parse(config[:stdout]), globals, rest)
        rescue CLI::Exit
          raise
        rescue StandardError => e
          error_line("Error: #{e.message}")
          1
        end
      end

      private

      def error_line(text) = @err.puts(Colors.red(text, io: @err))
      def warn_line(text) = @err.puts(Colors.yellow(text, io: @err))

      # Reject a compose invocation whose own global flags do not parse.
      def assert_compose_globals(globals)
        error = Compose.compose_global_error(globals)
        raise UsageError.new(error, [ "See: rb-portless compose --help" ]) if error
      end

      def spawn_error_message(e)
        e.is_a?(SystemCallError) ? "#{e.class.name.split('::').last} #{e.message}" : e.message
      end

      # Run docker compose and capture its output.
      def docker_compose(args, input = nil)
        stdout, stderr, status = Open3.capture3("docker", "compose", *args, stdin_data: input.to_s)
        { status: status.exitstatus, stdout: stdout, stderr: stderr }
      rescue SystemCallError => e
        raise Error, "could not run docker compose: #{spawn_error_message(e)}"
      end

      # Run docker compose attached to this terminal. Returns a thread whose
      # value is the exit code; #pid is the child's pid (nil if it failed).
      def spawn_docker_compose(args, input = nil)
        opts = {}
        reader = nil
        if input
          reader, writer = IO.pipe
          opts[:in] = reader
        end
        begin
          pid = Process.spawn("docker", "compose", *args, **opts)
        rescue SystemCallError => e
          error_line("Error: could not run docker compose: #{spawn_error_message(e)}")
          return Thread.new { 1 }.tap { |t| t[:pid] = nil }
        ensure
          reader&.close
        end
        if writer
          begin
            writer.write(input)
          rescue Errno::EPIPE
            nil
          ensure
            writer.close
          end
        end
        thread = Thread.new do
          _, status = Process.wait2(pid)
          status.exitstatus || (status.signaled? ? 1 : 0)
        end
        thread[:pid] = pid
        thread
      end

      # Running containers of a compose invocation, or nil when `ps` fails.
      def read_compose_containers(globals, all: false, input: nil)
        result = docker_compose([ *globals, "ps", "--format", "json", *(all ? [ "--all" ] : []) ], input)
        return nil unless result[:status].zero?

        Compose.parse_containers(result[:stdout])
      rescue JSON::ParserError
        nil
      end

      # Project name from the compose file, or nil when there is none to read.
      def read_compose_project_name(globals, input = nil)
        config = docker_compose([ *globals, "config", "--format", "json" ], input)
        return nil unless config[:status].zero?

        JSON.parse(config[:stdout])["name"]
      rescue JSON::ParserError, NoMethodError, TypeError
        nil
      end

      # Files kept per compose project: the resolved model and its fixed ports.
      def compose_state_paths(state_dir, project)
        dir = File.join(state_dir, "compose")
        { model: File.join(dir, "#{project}.json"), ports: File.join(dir, "#{project}.ports.json") }
      end

      def new_store(dir)
        RouteStore.new(dir, on_warning: ->(msg) { warn_line(msg) })
      end

      def compose_down(args, globals, input)
        # An explicit name wins. Otherwise read it from the containers, so down
        # works without the compose file and after services were renamed, and
        # fall back to the file when no container is left.
        project = Compose.explicit_project(globals) ||
                  ENV["COMPOSE_PROJECT_NAME"] ||
                  read_compose_containers(globals, all: true, input: input)&.projects&.first ||
                  read_compose_project_name(globals, input)
        code = spawn_docker_compose(args, input).value
        # A failed down leaves the containers running, so their routes stay.
        return code if !code.zero? || project.nil? || project.empty?

        after = read_compose_containers([ "-p", project ])
        unless after
          warn_line("Could not read the project's containers. Routes were left in place.")
          return code
        end
        state = Daemon.discover_state
        store = new_store(state.dir)
        store.recover_corrupt_routes_file
        aliases = store.load_routes.select { |r| r.pid.to_i.zero? }
        Runner.remove_routes(store, Compose.stale_aliases(aliases, project, state.tlds, after))
        if after.ports.empty?
          # The resolved model can hold env_file values; drop it with the project.
          files = compose_state_paths(state.dir, project)
          FileUtils.rm_f(files[:model])
          FileUtils.rm_f(files[:ports])
        end
        code
      end

      # Refuse a project whose hostnames would collide with another project's,
      # like fd_x and fd-x.
      def assert_unique_project_label(state_dir, project)
        dir = File.join(state_dir, "compose")
        return unless File.directory?(dir)

        Dir.children(dir).each do |file|
          next if !file.end_with?(".json") || file.end_with?(".ports.json")

          # Compare the project name stored in the model, not the file name:
          # older versions named the file after the hostname label.
          other = begin
            JSON.parse(File.read(File.join(dir, file)))["name"]
          rescue StandardError
            next
          end
          next unless other != project && Compose.project_label(other.to_s) == Compose.project_label(project)

          raise Error, "Projects \"#{other}\" and \"#{project}\" share the hostname suffix " \
                       "#{Compose.project_label(project)}. Run rb-portless compose -p #{other} down, or rename one project."
        end
      end

      def port_free?(port)
        FreePort.find(port, port)
        true
      rescue Error
        false
      end

      # Ports saved by every other compose project in the state dir.
      def reserved_compose_ports(state_dir, project)
        dir = File.join(state_dir, "compose")
        reserved = []
        return reserved unless File.directory?(dir)

        own = File.basename(compose_state_paths(state_dir, project)[:ports])
        Dir.children(dir).each do |file|
          next if !file.end_with?(".ports.json") || file == own

          begin
            ports = JSON.parse(File.read(File.join(dir, file)))
            ports.each_value { |port| reserved << port if port.is_a?(Numeric) } if ports.is_a?(Hash)
          rescue StandardError
            # Unreadable file: nothing to reserve.
          end
        end
        reserved
      end

      # Fixed host ports for the project's routed container ports, saved for the next up.
      def allocate_compose_ports(state_dir, project, keys)
        ports_path = compose_state_paths(state_dir, project)[:ports]
        stored = begin
          JSON.parse(File.read(ports_path))
        rescue StandardError
          {} # First run, or an unreadable file: allocate fresh ports.
        end
        stored = {} unless stored.is_a?(Hash)
        ports = Compose.allocate_ports(
          keys, stored,
          min: MIN_PORT, max: MAX_PORT,
          ours: read_compose_containers([ "-p", project ])&.ports&.values || [],
          reserved: reserved_compose_ports(state_dir, project),
          free: method(:port_free?)
        )
        File.write(ports_path, JSON.pretty_generate(ports), perm: 0o600)
        ports
      end

      def alias_conflict?(store, hostname)
        store.recover_corrupt_routes_file
        store.load_routes.any? { |r| r.hostname == hostname && r.pid.to_i.zero? }
      end

      def report_hosts_sync(hostnames, port, tls, lan_mode)
        Daemon.report_hosts_sync(hostnames, port, tls, lan_mode) { |msg| warn_line(msg) }
      end

      def resolve_state
        state = Daemon.discover_state
        ensured = Daemon.ensure_proxy_running(state.port, state.tls, Daemon.resolve_desired_state(state.lan_mode))
        if ensured[:started]
          state = ensured[:state]
          CLI.handle_trust if state.tls && !Trust.trusted?(state.dir)
        else
          running = Daemon.read_current_proxy_config(state.dir)
          state = state.dup
          state.tlds = running.tlds
          state.lan_mode = running.lan_mode
          state.lan_ip = running.lan_ip
        end
        state
      end

      def compose_up(source, globals, rest)
        state = resolve_state
        dir = state.dir
        proxy_port = state.port
        tls = state.tls
        tlds = state.tlds
        lan_mode = state.lan_mode
        store = new_store(dir)

        project = source["name"]
        files = compose_state_paths(dir, project)
        store.ensure_dir
        FileUtils.mkdir_p(File.dirname(files[:model]))
        State.fix_ownership(File.dirname(files[:model]))
        assert_unique_project_label(dir, project)

        plan_opts = {
          hostnames_for: ->(name) { Runner.build_hostnames(name, tlds) },
          url_for: ->(hostname) { Utils.format_url(hostname, proxy_port, tls) },
          vite_allowed_hosts: Runner.format_vite_allowed_hosts(tlds)
        }
        # Plan once to learn the routed ports, then again with their fixed host ports.
        key_of = ->(service, target) { "#{service}:#{target}" }
        keys = Compose.plan_compose(source, **plan_opts).routes.map { |r| key_of.(r.service, r.target) }.uniq
        ports = allocate_compose_ports(dir, project, keys)
        plan = Compose.plan_compose(source, **plan_opts, port_for: ->(service, target) { ports[key_of.(service, target)] })

        File.write(files[:model], JSON.pretty_generate(plan.model), perm: 0o600)
        State.fix_ownership(files[:model], files[:ports])

        @err.puts(Colors.bold("\nrb-portless compose #{plan.project}\n", io: @err))
        plan.kept.each do |k|
          where = k.published ? "host port #{k.published}" : "an ephemeral port"
          verb = k.dropped ? "drops" : "keeps"
          @err.puts(Colors.gray("  #{k.service}:#{k.target} #{verb} #{where} (#{k.reason})", io: @err))
        end
        warn_line("No published HTTP ports found. Nothing to route.") if plan.routes.empty?

        up_args = Compose.build_up_args(
          globals: globals, rest: rest, project: plan.project, model_path: files[:model], cwd: Dir.pwd,
          compose_file_env: ENV["COMPOSE_FILE"], path_separator: ENV["COMPOSE_PATH_SEPARATOR"]
        )
        detached = Compose.detached_up?(rest)
        owner_pid = detached ? 0 : Process.pid
        registered = {}
        # Conflicts are retried on every sync (the owner may exit) but reported once.
        conflicts = []

        # Register the routes of running services. Ports are fixed, so this
        # only picks up services as they start.
        sync = lambda do
          containers = read_compose_containers([ "-p", plan.project ])
          next false unless containers

          plan.routes.each do |route|
            port = Compose.route_port(route, containers)
            primary = route.hostnames.first
            next if port.nil? || registered[primary] == port

            begin
              # Aliases from an earlier up -d are ours to replace; a live process is not.
              Runner.add_routes(store, route.hostnames, port, owner_pid, alias_conflict?(store, primary))
            rescue RouteConflictError => e
              unless conflicts.include?(primary)
                error_line("Error: #{primary} is already registered by another process (PID #{e.existing_pid}). " \
                           "Stop it, or rename the service with portless.name.")
              end
              conflicts << primary unless conflicts.include?(primary)
              next
            end
            conflicts.delete(primary)
            registered[primary] = port
            @err.puts(Colors.cyan("  -> #{route.url}  (#{route.service}:#{route.target})", io: @err))
          end
          true
        end

        if detached
          code = spawn_docker_compose(up_args).value
          if code.zero?
            @err.puts("")
            unless sync.call
              warn_line("Could not read the project's containers, so no routes were registered. " \
                        "Run rb-portless compose up -d again.")
            end
            report_hosts_sync(registered.keys, proxy_port, tls, lan_mode) unless registered.empty?
          end
          return code.zero? ? (conflicts.empty? ? 0 : 1) : code
        end

        # Foreground: compose owns the terminal. Routes are registered as
        # services start and dropped when compose exits.
        child = spawn_docker_compose(up_args)
        reported = false
        stop = Queue.new
        # Stopped through the queue, never killed, so a sync never dies holding the routes lock.
        timer = Thread.new do
          while stop.pop(timeout: 1).nil?
            sync.call
            if !reported && !registered.empty?
              reported = true
              hostnames = registered.keys
              Thread.new { report_hosts_sync(hostnames, proxy_port, tls, lan_mode) }
            end
          end
        end
        # Ctrl+C reaches compose through the process group; wait for it to stop.
        previous_int = trap("INT") { }
        previous_term = trap("TERM") do
          Process.kill("TERM", child[:pid]) if child[:pid]
        rescue SystemCallError
          nil
        end
        begin
          code = child.value
        ensure
          stop << true
          timer.join
          trap("INT", previous_int || "DEFAULT")
          trap("TERM", previous_term || "DEFAULT")
        end
        plan.routes.each { |route| Runner.remove_routes(store, route.hostnames, Process.pid) }
        FileUtils.rm_f(files[:model])
        code
      end
    end
  end
end
