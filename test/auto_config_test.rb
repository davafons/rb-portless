# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Ported from portless auto.test.ts, config.test.ts, workspace.test.ts,
# turbo.test.ts and the utils.ts hostname/TLD helpers.
class AutoConfigTest < Minitest::Test
  def write_json(dir, file, data)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, file), JSON.generate(data))
  end

  # ── auto.ts ──────────────────────────────────────────────────────────────
  def test_sanitize_and_truncate
    a = Portless::Auto
    assert_equal "my-app", a.sanitize_for_hostname("My_App!!")
    assert_equal "a-b", a.sanitize_for_hostname("--a---b--")
    long = "x" * 70
    t = a.truncate_label(long)
    assert_equal 63, t.length
    assert_match(/\Ax{56}-[0-9a-f]{6}\z/, t)
    assert_equal "short", a.truncate_label("short")
  end

  def test_infer_project_name_prefers_package_json_and_strips_scope
    Dir.mktmpdir do |dir|
      write_json(dir, "package.json", { "name" => "@acme/web-app" })
      sub = File.join(dir, "src")
      FileUtils.mkdir_p(sub)
      inferred = Portless::Auto.infer_project_name(sub)
      assert_equal [ "web-app", "package.json" ], [ inferred.name, inferred.source ]
    end
  end

  def test_infer_project_name_falls_back_to_directory
    Dir.mktmpdir do |dir|
      d = File.join(dir, "My Project")
      FileUtils.mkdir_p(d)
      name = Portless::Auto.infer_project_name(d)
      assert_equal "my-project", name.name
      assert_includes [ "directory name", "git root" ], name.source
    end
  end

  def test_apply_worktree_prefix
    a = Portless::Auto
    wt = a::WorktreePrefix.new("auth", "git branch")
    assert_equal "myapp", a.apply_worktree_prefix("myapp", nil)
    assert_equal "auth.myapp", a.apply_worktree_prefix("myapp", wt)
    assert_equal "myapp-auth", a.apply_worktree_prefix("myapp", wt, "{name}-{worktree}")
    assert_equal "auth.app.MYAPP".downcase, a.apply_worktree_prefix("MYAPP", wt, "{worktree}.app.{name}")
  end

  def test_branch_to_prefix_and_env_override
    a = Portless::Auto
    assert_nil a.branch_to_prefix("main", "last-segment")
    assert_nil a.branch_to_prefix("HEAD", "last-segment")
    assert_equal "auth", a.branch_to_prefix("feature/auth", "last-segment")
    assert_equal "feature-auth", a.branch_to_prefix("feature/auth", "branch")
    ENV["PORTLESS_PREFIX"] = "PR 42"
    assert_equal "pr-42", a.detect_worktree_prefix(Dir.pwd).prefix
    ENV["PORTLESS_PREFIX"] = ""
    assert_nil a.detect_worktree_prefix(Dir.pwd)
  ensure
    ENV.delete("PORTLESS_PREFIX")
  end

  # ── config.ts ────────────────────────────────────────────────────────────
  def test_load_config_portless_json_then_package_json
    c = Portless::Config
    Dir.mktmpdir do |dir|
      assert_nil c.load_config(dir)
      write_json(dir, "package.json", { "portless" => "web" })
      loaded = c.load_config(dir)
      assert_equal [ { "name" => "web" }, "package.json" ], [ loaded.config, loaded.source ]
      write_json(dir, "portless.json", { "name" => "api", "appPort" => 4100 })
      assert_equal "portless.json", c.load_config(dir).source
    end
  end

  def test_validation_errors
    c = Portless::Config
    {
      { "name" => "" } => /"name" in .* must be a non-empty string/,
      { "appPort" => 70_000 } => /"appPort" .* integer between 1 and 65535/,
      { "proxy" => "no" } => /"proxy" .* must be a boolean/,
      { "turbo" => 1 } => /"turbo" .* must be a boolean/,
      { "apps" => [] } => /"apps" .* must be an object/,
      { "worktree" => { "prefix" => "x" } } => /must be "last-segment" or "branch"/,
      { "worktree" => { "hostnameTemplate" => "{name}" } } => /containing \{worktree\}/,
      { "worktree" => { "hostnameTemplate" => "{worktree}_x" } } => /valid hostname labels/
    }.each do |cfg, msg|
      Dir.mktmpdir do |dir|
        write_json(dir, "portless.json", cfg)
        err = assert_raises(Portless::ConfigValidationError) { c.load_config(dir) }
        assert_match msg, err.message
      end
    end
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "portless.json"), "{nope")
      assert_raises(Portless::ConfigValidationError) { c.load_config(dir) }
    end
  end

  def test_unknown_keys_warn
    Dir.mktmpdir do |dir|
      write_json(dir, "portless.json", { "tld" => "test" })
      _, err = capture_io { Portless::Config.load_config(dir) }
      assert_match(/Unknown key "tld"/, err)
    end
  end

  def test_resolve_app_config_path_keyed_apps
    config = { "worktree" => { "prefix" => "branch" },
               "apps" => { "apps/web" => { "name" => "web", "worktree" => { "hostnameTemplate" => "{worktree}-{name}" } } } }
    c = Portless::Config
    app = c.resolve_app_config(config, "/r", "/r/apps/web/src")
    assert_equal "web", app["name"]
    assert_equal({ "prefix" => "branch", "hostnameTemplate" => "{worktree}-{name}" }, app["worktree"])
    assert_equal({ "worktree" => { "prefix" => "branch" } }, c.resolve_app_config(config, "/r", "/r/other"))
  end

  def test_package_manager_detection_and_script_commands
    c = Portless::Config
    Dir.mktmpdir do |dir|
      write_json(dir, "package.json", { "scripts" => { "dev" => "vite" } })
      assert_equal "npm", c.detect_package_manager(dir)
      assert_equal %w[npm run dev -- --x], c.resolve_script_command("dev", dir, [ "--x" ])
      File.write(File.join(dir, "pnpm-lock.yaml"), "")
      assert_equal %w[pnpm run dev], c.resolve_script_command("dev", dir)
      write_json(dir, "package.json", { "packageManager" => "bun@1.1", "scripts" => { "dev" => "vite" } })
      assert_equal %w[bun run dev -- -- --x], c.resolve_script_command("dev", dir, %w[-- --x])
      assert_nil c.resolve_script_command("start", dir)
    end
    assert_equal %w[npx turbo], c.package_manager_exec("npm", [ "turbo" ])
    assert_equal %w[yarn exec -- turbo], c.package_manager_exec("yarn", [ "turbo" ])
  end

  def test_split_command_and_server_detection
    c = Portless::Config
    assert_equal [ "vite", "--open", "a b", "c'd" ], c.split_command(%q(vite --open "a b" c\'d))
    refute c.server_command?(%w[tsc -w])
    assert c.server_command?(%w[vite])
  end

  # ── workspace.ts / turbo.ts ──────────────────────────────────────────────
  def test_workspace_discovery
    Dir.mktmpdir do |root|
      File.write(File.join(root, "pnpm-workspace.yaml"), "packages:\n  - 'apps/*'\n  - \"!apps/skip\"\n")
      write_json(File.join(root, "apps/web"), "package.json", { "name" => "@acme/web", "scripts" => { "dev" => "vite" } })
      write_json(File.join(root, "apps/skip"), "package.json", { "name" => "skip" })
      assert_equal root, Portless::Workspace.find_workspace_root(File.join(root, "apps/web"))
      pkgs = Portless::Workspace.discover_workspace_packages(root)
      assert_equal [ [ "web", "acme" ] ], pkgs.map { |p| [ p.name, p.scope ] }
    end
    assert_equal %w[a b], Portless::Workspace.parse_pnpm_workspace_yaml("packages: ['a', \"b\"]\n")
  end

  def test_workspace_globs_skip_symlinked_dirs
    Dir.mktmpdir do |root|
      write_json(root, "package.json", { "workspaces" => [ "apps/*" ] })
      write_json(File.join(root, "apps/web"), "package.json", { "name" => "web" })
      write_json(File.join(root, "elsewhere"), "package.json", { "name" => "linked" })
      File.symlink(File.join(root, "elsewhere"), File.join(root, "apps/linked"))
      assert_equal [ "web" ], Portless::Workspace.discover_workspace_packages(root).map(&:name)
    end
  end

  def test_integral_float_app_port_is_accepted
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "portless.json"), '{ "appPort": 3000.0, "apps": { "web": { "appPort": 3e3 } } }')
      config = Portless::Config.load_config(dir).config
      assert_equal [ 3000, 3000 ], [ config["appPort"], config.dig("apps", "web", "appPort") ]
      assert_kind_of Integer, config["appPort"]
      File.write(File.join(dir, "portless.json"), '{ "appPort": 3000.5 }')
      assert_raises(Portless::ConfigValidationError) { Portless::Config.load_config(dir) }
    end
  end

  def test_locale_compare_key_matches_icu_order
    labels = [ "Beta", "beta", "@scope/web", "Admin", "api", "web-2", "web_1", "web1", "Web", "a.b", "a-b", "a b",
               "_x", "-x", "zeta", "\u00C1pple", "apple", "10", "9" ]
    # Node: labels.sort((a, b) => a.localeCompare(b))
    expected = [ "_x", "-x", "@scope/web", "10", "9", "a b", "a-b", "a.b", "Admin", "api", "apple", "\u00C1pple",
                 "beta", "Beta", "Web", "web_1", "web-2", "web1", "zeta" ]
    assert_equal expected, labels.sort_by { |l| Portless::Utils.locale_compare_key(l) }
  end

  def test_turbo_manifest_and_node_options
    Dir.mktmpdir do |dir|
      t = Portless::Turbo
      t.ensure_env_loader(dir)
      assert_includes File.read(t.loader_path(dir)), "dev-manifest.json"
      t.write_manifest({ "/x" => { "PORT" => "1" } }, dir)
      assert_equal({ "/x" => { "PORT" => "1" } }, JSON.parse(File.read(t.manifest_path(dir))))
      t.remove_manifest(dir)
      refute File.exist?(t.manifest_path(dir))
      assert_equal "--require #{t.loader_path(dir)}", t.build_node_options(dir) unless ENV["NODE_OPTIONS"]
      refute t.turbo_config?(dir)
    end
  end

  # ── utils ────────────────────────────────────────────────────────────────
  def test_hostnames_and_urls
    u = Portless::Utils
    assert_equal %w[api.myapp.localhost], u.parse_hostnames("api.myapp", [ "localhost" ])
    assert_equal %w[app.localhost app.test], u.parse_hostnames("app.localhost", %w[localhost test])
    assert_equal %w[app.test], u.parse_hostnames("app", %w[localhost test], [ "test" ])
    assert_raises(Portless::Error) { u.parse_hostname("a..b") }
    assert_equal "https://a.localhost", u.format_url("a.localhost", 443, true)
    assert_equal "https://a.localhost:1355", u.format_url("a.localhost", 1355, true)
    assert_equal "http://a.localhost", u.format_url("a.localhost", 80, false)
    assert_nil u.parse_port("0")
    assert_equal 80, u.parse_port(" 80 ")
    assert_equal "2m", u.format_uptime(1_000, 1_000 + 150_000)
    assert_nil u.format_uptime(nil, 1)
  end

  def test_tld_helpers
    u = Portless::Utils
    assert_equal %w[localhost test], u.parse_tld_list(" localhost, TEST ,localhost")
    assert_raises(Portless::Error) { u.parse_tld_list("bad_tld") }
    assert_match(/HSTS/, u.risky_tld_reason("example.dev"))
    assert_nil u.risky_tld_reason("example.com")
    ENV["PORTLESS_TLD"] = "test,localhost"
    assert_equal %w[test localhost], u.default_tlds
  ensure
    ENV.delete("PORTLESS_TLD")
  end
end
