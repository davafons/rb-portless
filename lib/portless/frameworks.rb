# frozen_string_literal: true

module Portless
  # --port/--host injection for dev servers that ignore $PORT, seen through
  # package runners (npx/bunx/yarn dlx…) and one level of package script
  # (`npm run dev`), plus the script-forwarding analysis zero-arg and Turbo
  # mode need. Mirrors the framework section of portless's cli-utils.ts.
  module Frameworks
    module_function

    Spec = Struct.new(:strict_port, :server_subcommands, :non_server_subcommands, :default_is_server,
                      :positional_root_is_server, :value_flags, :host_flag, keyword_init: true)

    FRAMEWORKS_NEEDING_PORT = {
      "vite" => Spec.new(
        strict_port: true, server_subcommands: %w[dev serve preview], non_server_subcommands: %w[build optimize],
        default_is_server: true, positional_root_is_server: true,
        value_flags: %w[--assetsDir --assetsInlineLimit --base --configLoader --host --manifest --minify --open
                        --outDir --port --sourcemap --ssr --ssrManifest --target -c --config -d --debug -f
                        --filter -l --logLevel -m --mode]
      ),
      "vitepress" => Spec.new(strict_port: true, server_subcommands: %w[dev serve preview],
                              non_server_subcommands: %w[build init], default_is_server: true),
      "vp" => Spec.new(strict_port: true, server_subcommands: %w[dev], default_is_server: false),
      "react-router" => Spec.new(strict_port: true, server_subcommands: %w[dev], default_is_server: false),
      "rsbuild" => Spec.new(
        strict_port: false, server_subcommands: %w[dev preview], default_is_server: true,
        value_flags: %w[--base --config-loader --dist-path --env-dir --env-mode --environment --host --log-level
                        --output --port -c --config -m --mode -o --open -r --root]
      ),
      "astro" => Spec.new(
        strict_port: false, server_subcommands: %w[dev preview], default_is_server: false,
        value_flags: %w[--base --config --host --mode --open --outDir --port --root --site]
      ),
      "ng" => Spec.new(strict_port: false, server_subcommands: %w[serve dev s], default_is_server: false),
      "react-native" => Spec.new(strict_port: false, server_subcommands: %w[start], default_is_server: false),
      "expo" => Spec.new(strict_port: false, server_subcommands: %w[start serve], default_is_server: true),
      "wrangler" => Spec.new(strict_port: false, server_subcommands: %w[dev], default_is_server: false,
                             host_flag: "--ip")
    }.freeze

    Runner = Struct.new(:subcommands, :value_flags, :separator_required, keyword_init: true)

    PACKAGE_RUNNERS = {
      "npx" => Runner.new(subcommands: [], value_flags: %w[-c --call -p --package -w --workspace --allow-scripts]),
      "bunx" => Runner.new(subcommands: []),
      "pnpx" => Runner.new(subcommands: [], value_flags: %w[-p --package]),
      "yarn" => Runner.new(subcommands: %w[dlx exec]),
      "pnpm" => Runner.new(subcommands: %w[dlx exec]),
      "npm" => Runner.new(subcommands: %w[exec x], value_flags: %w[-c --call --package -w --workspace --prefix],
                          separator_required: true)
    }.freeze

    PACKAGE_SCRIPT_MANAGERS = %w[npm pnpm yarn bun].freeze
    ENV_ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/
    MAX_SCRIPT_DELEGATION_DEPTH = 5

    Invocation = Struct.new(:basename, :framework, :framework_index, :framework_args, :insertion_index,
                            :separator, keyword_init: true)

    # Wrappers a root script may put in front of Turbo (COMMAND_WRAPPERS).
    NPM_EXEC = { consumes: "unless separated", package_spec: true }.freeze
    COMMAND_WRAPPERS = {
      "env" => { value_flags: %w[-u --unset] },
      "cross-env" => {},
      "dotenv" => { value_flags: %w[-e -v], consumes: "unless separated" },
      "npx" => { value_flags: PACKAGE_RUNNERS["npx"].value_flags, package_spec: true },
      "bunx" => { package_spec: true },
      "pnpx" => { value_flags: PACKAGE_RUNNERS["pnpx"].value_flags, package_spec: true },
      "npm" => { value_flags: PACKAGE_RUNNERS["npm"].value_flags,
                 subcommands: { "exec" => NPM_EXEC, "x" => NPM_EXEC,
                                "run" => { consumes: "always", script: "always" } } },
      "pnpm" => { subcommands: { "exec" => {}, "dlx" => { package_spec: true }, "run" => { script: "always" } } },
      "yarn" => { consumes: "always", classic_only: true, script: "maybe",
                  subcommands: { "exec" => { consumes: "unless separated", classic_only: true },
                                 "dlx" => { package_spec: true },
                                 "run" => { consumes: "always", classic_only: true, script: "always" } } },
      "bun" => { bare: false,
                 subcommands: { "x" => { package_spec: true }, "run" => { consumes: "always", script: "always" } } }
    }.freeze

    def skip_runner_prefix(args, start, value_flags)
      index = start
      separator = false
      while index < args.length && args[index].start_with?("-")
        option = args[index]
        index += 1
        if option == "--"
          separator = true
          break
        end
        index += 1 if !option.include?("=") && value_flags&.include?(option)
      end
      [ index, separator ]
    end

    def parse_framework_invocation(args)
      return nil if args.empty?

      first = File.basename(args[0])
      framework_index = FRAMEWORKS_NEEDING_PORT[first] ? 0 : nil
      runner_separator = false
      needs_separator = false

      if framework_index.nil?
        runner = PACKAGE_RUNNERS[first] or return nil
        i, runner_separator = skip_runner_prefix(args, 1, runner.value_flags)

        unless runner.subcommands.empty?
          return nil if i >= args.length

          if runner.subcommands.include?(args[i])
            i, sep = skip_runner_prefix(args, i + 1, runner.value_flags)
            runner_separator ||= sep
          else
            framework_index = FRAMEWORKS_NEEDING_PORT[File.basename(args[i])] ? i : nil
          end
        end

        if framework_index.nil?
          i, sep = skip_runner_prefix(args, i, runner.value_flags)
          runner_separator ||= sep
          return nil if i >= args.length

          framework_index = FRAMEWORKS_NEEDING_PORT[File.basename(args[i])] ? i : nil
        end
        needs_separator = !!runner.separator_required && !runner_separator if framework_index
      end

      return nil if framework_index.nil?

      basename = File.basename(args[framework_index])
      framework = FRAMEWORKS_NEEDING_PORT[basename]
      option_end = (framework_index + 1...args.length).find { |j| args[j] == "--" }
      insertion_index = needs_separator || option_end.nil? ? args.length : option_end
      framework_args =
        if needs_separator
          before = option_end ? args[(framework_index + 1)...option_end] : args[(framework_index + 1)..]
          may_consume = before.each_with_index.any? do |arg, j|
            arg.start_with?("-") && !arg.include?("=") && j + 1 < before.length && !before[j + 1].start_with?("-")
          end
          may_consume ? nil : before.reject { |a| a.start_with?("-") } + (option_end ? args[(option_end + 1)..] : [])
        else
          args[(framework_index + 1)...insertion_index]
        end
      Invocation.new(basename: basename, framework: framework, framework_index: framework_index,
                     framework_args: framework_args, insertion_index: insertion_index,
                     separator: needs_separator && option_end.nil? ? "--" : nil)
    end

    def find_framework_basename(args) = parse_framework_invocation(args)&.basename

    def command_basename(token) = File.basename(token)

    def turbo_command?(token, package_spec)
      name = command_basename(token)
      name == "turbo" || (package_spec && !token.start_with?("@") && name.match?(%r{\Aturbo@[^/]+\z}))
    end

    def mentions_turbo?(args)
      args.any? { |a| (n = command_basename(a)) == "turbo" || n.match?(%r{\Aturbo@[^/]+\z}) }
    end

    # Strip env assignments and wrappers from the front of a script's tokens.
    def unwrap_command(tokens, package_dir)
      classic = Config.yarn_classic?(package_dir)
      command = tokens
      consumed = 0
      package_spec = false
      script = nil
      loop do
        first = command[0]
        return nil if first.nil?

        if first.match?(ENV_ASSIGNMENT)
          command = command[1..]
          next
        end
        name = command_basename(first)
        spec = COMMAND_WRAPPERS[name]
        return { command: command, consumed: consumed, package_spec: package_spec, script: script } unless spec

        index, separator = skip_runner_prefix(command, 1, spec[:value_flags])
        wrapped = spec
        sub = spec[:subcommands]&.[](command[index].to_s)
        if sub
          wrapped = sub
          index, separator = sub[:script] ? [ index + 1, false ] : skip_runner_prefix(command, index + 1, spec[:value_flags])
        elsif spec[:bare] == false
          return { command: command, consumed: consumed, package_spec: package_spec, script: script }
        end
        if wrapped[:script] == "always"
          target = command[index]
          return nil if target.nil? || target.start_with?("-")

          wrapped = {} if name == "bun" && !Config.resolve_script(target, package_dir)
        end
        if wrapped[:consumes] && (!wrapped[:classic_only] || classic) &&
           (wrapped[:consumes] == "always" || !separator)
          consumed += 1
        end
        package_spec = wrapped[:package_spec] == true
        script = wrapped[:script]
        command = command[index..] || []
        return { command: command, consumed: consumed, package_spec: package_spec, script: script } if script == "always"
      end
    end

    def framework_positionals(args, framework)
      positionals = []
      i = 0
      while i < args.length
        arg = args[i]
        break if arg == "--"

        if !arg.start_with?("-")
          positionals << arg
        elsif arg.include?("=")
          nil
        elsif framework.value_flags&.include?(arg)
          i += 1
        elsif framework.value_flags.nil? && positionals.empty?
          return nil
        end
        i += 1
      end
      positionals
    end

    def invokes_framework_server?(framework_args, framework)
      positionals = framework_positionals(framework_args, framework)
      return false if positionals.nil?

      subcommand = positionals.first
      return framework.default_is_server if subcommand.nil?
      return true if framework.server_subcommands.include?(subcommand)
      return false if framework.non_server_subcommands&.include?(subcommand)

      framework.positional_root_is_server == true
    end

    def cli_option?(args, option)
      args.any? { |a| a == option || a.start_with?("#{option}=") }
    end

    # Mutates `args` in place, appending --port/--host for a framework server
    # that ignores $PORT. Returns the inserted tokens.
    def inject_framework_flags(args, port)
      inv = parse_framework_invocation(args) or return []
      fargs = inv.framework_args
      return [] if fargs.nil? || !invokes_framework_server?(fargs, inv.framework)

      flags = []
      unless cli_option?(fargs, "--port")
        flags.push("--port", port.to_s)
        flags << "--strictPort" if inv.framework.strict_port
      end
      host_flag = inv.framework.host_flag || "--host"
      host_choice = cli_option?(fargs, host_flag) ||
                    (inv.basename == "expo" && %w[--localhost --lan --tunnel].any? { |o| cli_option?(fargs, o) })
      if !host_choice && !(inv.basename == "expo" && Utils.lan_env_enabled?)
        flags.push(host_flag, inv.basename == "expo" ? "localhost" : "127.0.0.1")
      end

      inserted = inv.separator && !flags.empty? ? [ inv.separator, *flags ] : flags
      args.insert(inv.insertion_index, *inserted)
      inserted
    end

    # Would appending args to this raw script change what the shell runs?
    def unsafe_to_append_args?(command)
      in_single = in_double = escaped = false
      at_word_start = true
      chars = command.chars
      chars.each_with_index do |ch, i|
        if escaped
          escaped = false
          next if [ "\n", "\r" ].include?(ch)

          at_word_start = false
          next
        end
        if ch == "\\" && !in_single
          escaped = true
          next
        end
        if ch == "'" && !in_double
          in_single = !in_single
          at_word_start = false
          next
        end
        if ch == '"' && !in_single
          in_double = !in_double
          at_word_start = false
          next
        end
        next if in_single || in_double
        return true if [ ";", "\n", "\r", "|" ].include?(ch)
        return true if ch == "#" && at_word_start

        if ch == "&"
          nxt = chars[i + 1]
          next if i.positive? && chars[i - 1] == ">" && nxt&.match?(/[0-9-]/)

          return true
        end
        at_word_start = [ " ", "\t" ].include?(ch)
      end
      false
    end

    def resolve_package_script_tokens(args, package_dir)
      return nil if args.length < 3
      return nil unless PACKAGE_SCRIPT_MANAGERS.include?(File.basename(args[0]))

      _, sub, script_name = args
      return nil if sub != "run" || script_name.start_with?("-")

      Config.resolve_script(script_name, package_dir)
    end

    def safe_to_inject_into_script?(script_name, raw_script, package_dir)
      raw_text = Config.resolve_script_raw(script_name, package_dir)
      return false if raw_text && unsafe_to_append_args?(raw_text)

      inv = parse_framework_invocation(raw_script)
      return false if inv && raw_script[(inv.framework_index + 1)..].include?("--")

      true
    end

    def resolve_framework_basename(args, package_dir = Dir.pwd)
      direct = find_framework_basename(args)
      return direct if direct

      tokens = resolve_package_script_tokens(args, package_dir)
      tokens ? find_framework_basename(tokens) : nil
    end

    def walk_script(script_name, package_dir, chain)
      raw = Config.resolve_script_raw(script_name, package_dir)
      tokens = Config.resolve_script(script_name, package_dir)
      return { kind: "missing" } if raw.nil? || tokens.nil?
      return { kind: "unsafe", script_name: script_name, turbo: mentions_turbo?(tokens) } if unsafe_to_append_args?(raw)

      un = unwrap_command(tokens, package_dir)
      return { kind: "leaf", separators: 0, turbo: false } unless un

      command = un[:command]
      literal = command[1..].count("--")
      if un[:script] != "always" && turbo_command?(command[0], un[:package_spec])
        return { kind: "leaf", separators: [ 0, un[:consumed] + 1 - literal ].max, turbo: true }
      end
      if un[:script].nil? || chain.include?(command[0]) || !Config.resolve_script(command[0], package_dir)
        return { kind: "leaf", separators: [ 0, un[:consumed] - literal ].max, turbo: false }
      end
      return { kind: "too-deep" } if chain.length - 1 >= MAX_SCRIPT_DELEGATION_DEPTH

      child = walk_script(command[0], package_dir, [ *chain, command[0] ])
      return child if %w[too-deep unsafe].include?(child[:kind])

      child_seps = child[:kind] == "leaf" ? child[:separators] : 0
      { kind: "leaf", separators: [ 0, un[:consumed] + child_seps - literal ].max,
        turbo: child[:kind] == "leaf" && child[:turbo] }
    end

    def resolve_turbo_root_forwarding(script_name, package_dir)
      r = walk_script(script_name, package_dir, [ script_name ])
      return { kind: "unsafe", turbo: r[:turbo] } if r[:kind] == "unsafe"
      return r if r[:kind] == "too-deep"
      return { kind: "forward", separators: r[:separators] } if r[:kind] == "leaf" && r[:turbo]

      { kind: "none" }
    end

    def resolve_script_arg_forwarding(script_name, package_dir)
      r = walk_script(script_name, package_dir, [ script_name ])
      return r if %w[missing too-deep].include?(r[:kind])
      return { kind: "unsafe", script_name: r[:script_name] } if r[:kind] == "unsafe"

      { kind: "forward", separators: r[:separators] }
    end

    # `<pm> run <script>`: resolve the script, compute the flags its framework
    # needs and forward them through the package manager (npm needs `--`).
    def inject_package_script_framework_flags(args, port, package_dir = Dir.pwd)
      raw_script = resolve_package_script_tokens(args, package_dir) or return
      return unless safe_to_inject_into_script?(args[2], raw_script, package_dir)

      probe = raw_script + args[3..].reject { |a| a == "--" }
      forwarded = inject_framework_flags(probe, port)
      return if forwarded.empty?

      args << "--" if File.basename(args[0]) == "npm" && !args.include?("--")
      args.concat(forwarded)
    end
  end
end
