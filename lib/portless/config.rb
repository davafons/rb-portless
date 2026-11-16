# frozen_string_literal: true

require "json"

module Portless
  class ConfigValidationError < Error; end

  # portless.json / package.json "portless" config, package scripts and
  # package-manager detection. Mirrors portless's config.ts (plus cli.ts
  # loadAppConfig). Configs stay plain JSON hashes with upstream's camelCase
  # keys: name, script, appPort, proxy, worktree {prefix, hostnameTemplate},
  # apps (path-keyed), turbo.
  module Config
    module_function

    CONFIG_FILENAME = "portless.json"
    Loaded = Struct.new(:config, :config_dir, :source)

    KNOWN_TOP_KEYS = %w[name script appPort proxy apps turbo worktree].freeze
    KNOWN_APP_KEYS = %w[name script appPort proxy worktree].freeze
    KNOWN_WORKTREE_KEYS = %w[prefix hostnameTemplate].freeze

    LOCK_FILES = [
      [ "pnpm-lock.yaml", "pnpm" ], [ "yarn.lock", "yarn" ], [ "bun.lockb", "bun" ],
      [ "bun.lock", "bun" ], [ "package-lock.json", "npm" ]
    ].freeze

    BUILD_ONLY_COMMANDS = %w[tsup tsc esbuild rollup babel swc unbuild pkgroll ncc microbundle].freeze

    # portless.json first, then package.json "portless"; no walking up.
    def load_config(cwd = Dir.pwd)
      path = File.join(cwd, CONFIG_FILENAME)
      raw = begin
        File.read(path)
      rescue Errno::ENOENT
        return load_config_from_package_json(cwd)
      end
      parsed = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        raise ConfigValidationError, "Invalid JSON in #{path}"
      end
      validate_config(parsed, path)
      Loaded.new(parsed, cwd, "portless.json")
    end

    # A string "portless" value is shorthand for { name }.
    def normalize_portless_value(value)
      return value unless value.is_a?(String)

      value.strip.empty? ? nil : { "name" => value.strip }
    end

    def read_package_json(dir)
      JSON.parse(File.read(File.join(dir, "package.json")))
    rescue StandardError
      nil
    end

    def load_config_from_package_json(dir)
      pkg = read_package_json(dir)
      return nil unless pkg.is_a?(Hash) && pkg.key?("portless")

      config = normalize_portless_value(pkg["portless"])
      return nil if config.nil?

      validate_config(config, "#{File.join(dir, 'package.json')} \"portless\"")
      Loaded.new(config, dir, "package.json")
    end

    def load_package_portless_config(dir)
      pkg = read_package_json(dir)
      return nil unless pkg.is_a?(Hash) && pkg.key?("portless")

      config = normalize_portless_value(pkg["portless"])
      return nil unless config.is_a?(Hash)

      validate_app_config(config, "portless", File.join(dir, "package.json"))
      config
    end

    def merge_worktree_config(*configs)
      merged = configs.compact.reduce({}) { |acc, c| acc.merge(c) }
      merged.empty? ? nil : merged
    end

    # The AppConfig for package_dir: the nearest `apps` path key (walking the
    # relative path upward), else the top-level fields.
    def resolve_app_config(config, config_dir, package_dir)
      if config["apps"]
        rel = relative_path(config_dir, package_dir)
        if rel && !rel.empty? && !rel.start_with?("..")
          candidate = rel
          until candidate.empty?
            if (app = config["apps"][candidate])
              worktree = merge_worktree_config(config["worktree"], app["worktree"])
              return worktree ? app.merge("worktree" => worktree) : app
            end
            parent = File.dirname(candidate)
            break if parent == "." || parent == candidate

            candidate = parent
          end
        end
        worktree = merge_worktree_config(config["worktree"])
        return worktree ? { "worktree" => worktree } : {}
      end

      config.slice("name", "script", "appPort", "proxy", "worktree").compact
    end

    def relative_path(from, to)
      require "pathname"
      Pathname.new(File.expand_path(to)).relative_path_from(Pathname.new(File.expand_path(from))).to_s
                                         .then { |r| r == "." ? "" : r }
    rescue ArgumentError
      nil
    end

    # loadAppConfig (cli.ts): the effective config for cwd, merged with the
    # workspace root's worktree defaults. Adds "source".
    def load_app_config(cwd = Dir.pwd)
      loaded = load_config(cwd)
      root = Workspace.find_workspace_root(cwd)
      root_config = root && root != File.expand_path(cwd) ? load_config(root) : nil
      root_worktree = merge_worktree_config(
        root_config ? resolve_app_config(root_config.config, root_config.config_dir, cwd)["worktree"] : nil
      )
      unless loaded
        return root_config && root_worktree ? { "worktree" => root_worktree, "source" => root_config.source } : nil
      end

      local = resolve_app_config(loaded.config, loaded.config_dir, cwd)
      worktree = merge_worktree_config(root_worktree, local["worktree"])
      result = local.merge("source" => loaded.source)
      worktree ? result.merge("worktree" => worktree) : result
    end

    # ── package.json scripts ──────────────────────────────────────────────
    def resolve_script(script_name, package_dir)
      raw = resolve_script_raw(script_name, package_dir)
      raw ? split_command(raw) : nil
    end

    def resolve_script_raw(script_name, package_dir)
      value = read_package_json(package_dir)&.dig("scripts", script_name)
      value.is_a?(String) && !value.strip.empty? ? value : nil
    rescue StandardError
      nil
    end

    def script?(script_name, dir)
      read_package_json(dir)&.dig("scripts", script_name).is_a?(String)
    rescue StandardError
      false
    end

    def detect_package_manager(cwd)
      Auto.each_ancestor(cwd) do |dir|
        manager = read_package_json(dir)&.dig("packageManager")
        if manager.is_a?(String)
          name = manager.split("@").first
          return name if %w[pnpm yarn bun npm].include?(name)
        end
        LOCK_FILES.each { |file, pm| return pm if File.exist?(File.join(dir, file)) }
      end
      "npm"
    end

    def yarn_classic?(package_dir)
      Auto.each_ancestor(package_dir) do |dir|
        manager = read_package_json(dir)&.dig("packageManager")
        return manager.delete_prefix("yarn@").start_with?("1.") if manager.is_a?(String) && manager.start_with?("yarn@")

        lock = begin
          File.read(File.join(dir, "yarn.lock"))
        rescue StandardError
          nil
        end
        return true if lock&.include?("# yarn lockfile v1")
        return false if lock&.include?("__metadata:")
        return false if File.exist?(File.join(dir, ".yarnrc.yml"))
      end
      true
    end

    # npm needs `--` before script args; bun and Yarn Classic swallow a
    # leading `--`, so they get an extra one when the args start with it.
    def script_run_command(pm, script_name, package_dir, extra_args = [])
      return [ pm, "run", script_name ] if extra_args.empty?

      consumes = pm == "bun" || (pm == "yarn" && yarn_classic?(package_dir))
      separator = pm == "npm" || (consumes && extra_args.first == "--") ? [ "--" ] : []
      [ pm, "run", script_name, *separator, *extra_args ]
    end

    def package_manager_exec(pm, command_args)
      case pm
      when "npm" then [ "npx", *command_args ]
      when "bun" then [ "bunx", *command_args ]
      when "yarn" then [ "yarn", "exec", "--", *command_args ]
      else [ pm, "exec", *command_args ]
      end
    end

    def resolve_script_command(script_name, package_dir, extra_args = [])
      return nil unless script?(script_name, package_dir)

      script_run_command(detect_package_manager(package_dir), script_name, package_dir, extra_args)
    end

    # Whitespace split honouring quotes and backslash escapes.
    def split_command(command)
      args = []
      current = +""
      in_single = in_double = escaped = false
      command.each_char do |ch|
        if escaped
          current << ch
          escaped = false
        elsif ch == "\\" && !in_single
          escaped = true
        elsif ch == "'" && !in_double
          in_single = !in_single
        elsif ch == '"' && !in_single
          in_double = !in_double
        elsif ch.match?(/\s/) && !in_single && !in_double
          unless current.empty?
            args << current
            current = +""
          end
        else
          current << ch
        end
      end
      args << current unless current.empty?
      args
    end

    def server_command?(args)
      return false if args.empty?

      !BUILD_ONLY_COMMANDS.include?(File.basename(args.first))
    end

    # ── validation ────────────────────────────────────────────────────────
    def validate_config(config, path)
      raise ConfigValidationError, "#{path} must be a JSON object." unless config.is_a?(Hash)

      validate_common(config, nil, path)
      if config.key?("turbo") && ![ true, false ].include?(config["turbo"])
        raise ConfigValidationError, "\"turbo\" in #{path} must be a boolean."
      end
      validate_worktree_config(config["worktree"], "worktree", path) if config.key?("worktree")
      if config.key?("apps")
        raise ConfigValidationError, "\"apps\" in #{path} must be an object." unless config["apps"].is_a?(Hash)

        config["apps"].each do |key, value|
          raise ConfigValidationError, "\"apps.#{key}\" in #{path} must be an object." unless value.is_a?(Hash)

          validate_app_config(value, "apps.#{key}", path)
        end
      end
      warn_unknown_keys(config, KNOWN_TOP_KEYS, path)
    end

    def validate_app_config(obj, prefix, path)
      validate_common(obj, prefix, path)
      validate_worktree_config(obj["worktree"], "#{prefix}.worktree", path) if obj.key?("worktree")
      warn_unknown_keys(obj, KNOWN_APP_KEYS, path, prefix)
    end

    def validate_common(obj, prefix, path)
      key = ->(k) { prefix ? "#{prefix}.#{k}" : k }
      %w[name script].each do |k|
        next unless obj.key?(k)
        next if obj[k].is_a?(String) && !obj[k].strip.empty?

        raise ConfigValidationError, "\"#{key.(k)}\" in #{path} must be a non-empty string."
      end
      if obj.key?("appPort")
        # Number.isInteger: JSON 3000.0 / 3e3 are integers too.
        port = obj["appPort"]
        unless port.is_a?(Numeric) && port.finite? && port == port.to_i && port.between?(1, 65_535)
          raise ConfigValidationError, "\"#{key.('appPort')}\" in #{path} must be an integer between 1 and 65535."
        end

        obj["appPort"] = port.to_i
      end
      return unless obj.key?("proxy") && ![ true, false ].include?(obj["proxy"])

      raise ConfigValidationError, "\"#{key.('proxy')}\" in #{path} must be a boolean."
    end

    def validate_worktree_config(value, prefix, path)
      raise ConfigValidationError, "\"#{prefix}\" in #{path} must be an object." unless value.is_a?(Hash)

      if value.key?("prefix") && ![ "last-segment", "branch" ].include?(value["prefix"])
        raise ConfigValidationError, "\"#{prefix}.prefix\" in #{path} must be \"last-segment\" or \"branch\"."
      end
      template = value["hostnameTemplate"]
      if value.key?("hostnameTemplate") && !(template.is_a?(String) && template.include?("{worktree}"))
        raise ConfigValidationError,
              "\"#{prefix}.hostnameTemplate\" in #{path} must be a string containing {worktree}."
      end
      if template.is_a?(String)
        labels = template.gsub("{worktree}", "worktree").gsub("{name}", "name").split(".", -1)
        unless labels.all? { |l| l.match?(/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/i) }
          raise ConfigValidationError,
                "\"#{prefix}.hostnameTemplate\" in #{path} must render to valid hostname labels: \"#{template}\"."
        end
      end
      warn_unknown_keys(value, KNOWN_WORKTREE_KEYS, path, prefix)
    end

    def warn_unknown_keys(obj, known, path, prefix = nil)
      obj.each_key do |k|
        next if known.include?(k)

        label = prefix ? "\"#{prefix}.#{k}\"" : "\"#{k}\""
        warn "Warning: Unknown key #{label} in #{path}. Known keys: #{known.join(', ')}"
      end
    end
  end
end
