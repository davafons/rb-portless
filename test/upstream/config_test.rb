# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/config"

# Mirror of packages/portless/src/config.test.ts
module ConfigTestSetup
  include UpstreamConfigSupport

  def self.included(base)
    base.class_eval do
      before { @tmp_dir = create_tmp_dir("portless-config-test-") }
      after { cleanup_dir(@tmp_dir) }
    end
  end
end

describe "splitCommand" do
  def split_command(cmd) = Portless::Config.split_command(cmd)

  it "splits on whitespace" do
    _(split_command("next dev")).must_equal %w[next dev]
  end

  it "handles multiple spaces" do
    _(split_command("next   dev")).must_equal %w[next dev]
  end

  it "trims leading/trailing whitespace" do
    _(split_command("  next dev  ")).must_equal %w[next dev]
  end

  it "handles single-word command" do
    _(split_command("vitest")).must_equal [ "vitest" ]
  end

  it "returns empty array for empty string" do
    _(split_command("")).must_equal []
  end

  it "preserves single-quoted arguments" do
    _(split_command("NODE_OPTIONS='--max-old-space-size=4096' next dev")).must_equal [
      "NODE_OPTIONS=--max-old-space-size=4096", "next", "dev"
    ]
  end

  it "preserves double-quoted arguments" do
    _(split_command('echo "hello world"')).must_equal [ "echo", "hello world" ]
  end

  it "handles mixed quotes" do
    _(split_command(%(KEY='val with spaces' CMD="another arg"))).must_equal [
      "KEY=val with spaces", "CMD=another arg"
    ]
  end

  it "handles quotes within a token" do
    _(split_command("--flag='some value'")).must_equal [ "--flag=some value" ]
  end

  it "handles backslash-escaped double quotes" do
    _(split_command('echo \\"hello\\"')).must_equal [ "echo", '"hello"' ]
  end

  it "handles backslash-escaped single quotes" do
    _(split_command("echo \\'hello\\'")).must_equal [ "echo", "'hello'" ]
  end

  it "handles escaped backslash" do
    _(split_command("echo \\\\path")).must_equal [ "echo", "\\path" ]
  end

  it "handles backslash-escaped spaces" do
    _(split_command("path\\ with\\ spaces arg")).must_equal [ "path with spaces", "arg" ]
  end

  it "preserves backslash inside single quotes (POSIX behavior)" do
    _(split_command("echo 'hello\\nworld'")).must_equal [ "echo", "hello\\nworld" ]
  end
end

describe "loadConfig" do
  include ConfigTestSetup

  def load_config(dir) = Portless::Config.load_config(dir)

  it "returns null when no portless.json exists" do
    _(load_config(@tmp_dir)).must_be_nil
  end

  it "loads portless.json from cwd" do
    write_json(File.join(@tmp_dir, "portless.json"), { name: "myapp" })
    result = load_config(@tmp_dir)
    _(result).wont_be_nil
    _(result.config["name"]).must_equal "myapp"
    _(result.config_dir).must_equal @tmp_dir
    _(result.source).must_equal "portless.json"
  end

  it "does not walk up from a subdirectory" do
    write_json(File.join(@tmp_dir, "portless.json"), { name: "myapp" })
    sub_dir = File.join(@tmp_dir, "src", "components")
    FileUtils.mkdir_p(sub_dir)
    _(load_config(sub_dir)).must_be_nil
  end

  it "loads config with all fields" do
    config = { "name" => "myapp", "script" => "start", "appPort" => 3000 }
    write_json(File.join(@tmp_dir, "portless.json"), config)
    _(load_config(@tmp_dir).config).must_equal config
  end

  it "loads config with proxy field" do
    write_json(File.join(@tmp_dir, "portless.json"), { name: "myapp", proxy: false })
    _(load_config(@tmp_dir).config["proxy"]).must_equal false
  end

  it "loads config with apps map" do
    config = { apps: { "apps/web" => { name: "web" }, "apps/api" => { name: "api", script: "start" } } }
    write_json(File.join(@tmp_dir, "portless.json"), config)
    result = load_config(@tmp_dir)
    _(result.config["apps"]).wont_be_nil
    _(result.config["apps"].keys.length).must_equal 2
  end

  it "loads empty object config" do
    write(File.join(@tmp_dir, "portless.json"), "{}")
    result = load_config(@tmp_dir)
    _(result).wont_be_nil
    _(result.config).must_equal({})
  end

  it "loads config from package.json portless key" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", portless: { name: "myapp", script: "dev" } })
    result = load_config(@tmp_dir)
    _(result).wont_be_nil
    _(result.config["name"]).must_equal "myapp"
    _(result.config["script"]).must_equal "dev"
    _(result.config_dir).must_equal @tmp_dir
    _(result.source).must_equal "package.json"
  end

  it "loads string shorthand from package.json portless key" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", portless: "myapp" })
    result = load_config(@tmp_dir)
    _(result).wont_be_nil
    _(result.config["name"]).must_equal "myapp"
  end

  it "ignores empty string portless key" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", portless: "" })
    _(load_config(@tmp_dir)).must_be_nil
  end

  it "prefers portless.json over package.json portless key" do
    write_json(File.join(@tmp_dir, "portless.json"), { name: "from-file" })
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", portless: { name: "from-pkg" } })
    _(load_config(@tmp_dir).config["name"]).must_equal "from-file"
  end

  it "ignores package.json without portless key" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", scripts: { dev: "next dev" } })
    _(load_config(@tmp_dir)).must_be_nil
  end

  it "does not walk up to find package.json portless key" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", portless: { name: "root-app" } })
    sub_dir = File.join(@tmp_dir, "packages", "web")
    FileUtils.mkdir_p(sub_dir)
    _(load_config(sub_dir)).must_be_nil
  end
end

describe "loadConfig validation" do
  include ConfigTestSetup

  def load_config(dir) = Portless::Config.load_config(dir)

  def assert_invalid(content)
    write(File.join(@tmp_dir, "portless.json"), content.is_a?(String) ? content : JSON.generate(content))
    _ { load_config(@tmp_dir) }.must_raise Portless::ConfigValidationError
  end

  it "throws on invalid JSON" do
    assert_invalid("not json")
  end

  it "throws when config is an array" do
    assert_invalid("[]")
  end

  it "throws when name is a number" do
    assert_invalid({ name: 42 })
  end

  it "throws when name is empty string" do
    assert_invalid({ name: "" })
  end

  it "throws when appPort is out of range" do
    assert_invalid({ appPort: 99_999 })
  end

  it "throws when appPort is a string" do
    assert_invalid({ appPort: "3000" })
  end

  it "throws when apps entry is not an object" do
    assert_invalid({ apps: { "apps/web" => "bad" } })
  end

  it "rejects invalid worktree options" do
    cases = [
      [ "branch", /must be an object/ ],
      [ { prefix: "full" }, /last-segment/ ],
      [ { hostnameTemplate: "tenant.{name}" }, /\{worktree\}/ ],
      [ { hostnameTemplate: "" }, /hostnameTemplate/ ]
    ]
    cases.each do |worktree, message|
      write_json(File.join(@tmp_dir, "portless.json"), { worktree: worktree })
      _(_ { load_config(@tmp_dir) }.must_raise(Portless::ConfigValidationError).message).must_match message
    end
  end

  it "validates rendered hostnameTemplate labels in every config location" do
    valid = [
      "tenant.{worktree}",
      "{worktree}-{name}",
      "a.b.{worktree}",
      "UPPER-CASE.{worktree}",
      "#{'a' * 70}.{worktree}"
    ]
    invalid = [
      ".{worktree}",
      "tenant_{worktree}",
      "tenant.-{worktree}",
      "{worktree}.{tenant}",
      "a..{worktree}",
      "{worktree}."
    ]
    places = [
      [ "portless.json", ->(t) { { worktree: { hostnameTemplate: t } } }, '"worktree.hostnameTemplate"' ],
      [
        "portless.json",
        ->(t) { { apps: { "apps/web" => { worktree: { hostnameTemplate: t } } } } },
        '"apps.apps/web.worktree.hostnameTemplate"'
      ],
      [ "package.json", ->(t) { { portless: { worktree: { hostnameTemplate: t } } } }, '"worktree.hostnameTemplate"' ]
    ]

    places.each do |file, wrap, key|
      write_file = ->(t) { write_json(File.join(@tmp_dir, file), wrap.(t)) }
      valid.each do |t|
        write_file.(t)
        load_config(@tmp_dir)
      end
      invalid.each do |t|
        write_file.(t)
        error = _ { load_config(@tmp_dir) }.must_raise(Portless::ConfigValidationError)
        _(error.message).must_include "#{key} in #{File.join(@tmp_dir, file)}", t
      end
      FileUtils.rm_f(File.join(@tmp_dir, file))
    end
  end

  it "throws when proxy is not a boolean" do
    assert_invalid({ proxy: "false" })
  end

  it "accepts turbo as a boolean" do
    write_json(File.join(@tmp_dir, "portless.json"), { name: "test", turbo: false })
    _(load_config(@tmp_dir)&.config&.fetch("turbo")).must_equal false
  end

  it "throws when turbo is not a boolean" do
    assert_invalid({ turbo: "yes" })
  end

  it "warns on unknown top-level keys" do
    write_json(File.join(@tmp_dir, "portless.json"), { name: "myapp", typo: true })
    _, err = capture_io { load_config(@tmp_dir) }
    _(err).must_include '"typo"'
  end

  it "warns on unknown keys in apps entries" do
    write_json(File.join(@tmp_dir, "portless.json"), { apps: { "apps/web" => { name: "web", port: 3000 } } })
    _, err = capture_io { load_config(@tmp_dir) }
    _(err).must_include '"apps.apps/web.port"'
  end
end

describe "resolveAppConfig" do
  def resolve_app_config(*args) = Portless::Config.resolve_app_config(*args)

  it "returns top-level fields when no apps key" do
    config = { "name" => "myapp", "script" => "dev" }
    _(resolve_app_config(config, "/repo", "/repo")).must_equal({ "name" => "myapp", "script" => "dev" })
  end

  it "returns proxy field from top-level config" do
    config = { "name" => "myapp", "proxy" => false }
    _(resolve_app_config(config, "/repo", "/repo")["proxy"]).must_equal false
  end

  it "returns proxy field from apps entry" do
    config = { "apps" => { "apps/gen" => { "name" => "gen", "proxy" => false } } }
    _(resolve_app_config(config, "/repo", "/repo/apps/gen")["proxy"]).must_equal false
  end

  it "matches exact path in apps map" do
    config = { "apps" => { "apps/web" => { "name" => "web" }, "apps/api" => { "name" => "api" } } }
    _(resolve_app_config(config, "/repo", "/repo/apps/web")).must_equal({ "name" => "web" })
  end

  it "matches subdirectory to parent app entry" do
    config = { "apps" => { "apps/web" => { "name" => "web" } } }
    _(resolve_app_config(config, "/repo", "/repo/apps/web/src/components")).must_equal({ "name" => "web" })
  end

  it "returns empty object when no apps key matches" do
    config = { "apps" => { "apps/web" => { "name" => "web" } } }
    _(resolve_app_config(config, "/repo", "/repo/packages/shared")).must_equal({})
  end

  it "applies root worktree options and merges app overrides by key" do
    config = {
      "proxy" => false,
      "worktree" => { "prefix" => "branch", "hostnameTemplate" => "tenant.{worktree}-{name}" },
      "apps" => { "apps/api" => { "worktree" => { "prefix" => "last-segment" } } }
    }
    root = { "prefix" => "branch", "hostnameTemplate" => "tenant.{worktree}-{name}" }
    _(resolve_app_config(config, "/repo", "/repo/apps/web")).must_equal({ "worktree" => root })
    _(resolve_app_config(config, "/repo", "/repo/apps/api")).must_equal(
      { "worktree" => root.merge("prefix" => "last-segment") }
    )
  end

  it "ignores top-level fields when apps is present" do
    config = { "name" => "top-level", "apps" => { "apps/web" => { "name" => "web" } } }
    _(resolve_app_config(config, "/repo", "/repo/packages/other")).must_equal({})
  end

  it "handles Windows-style backslash paths" do
    config = { "apps" => { "apps/web" => { "name" => "web" } } }
    # path.relative on Windows returns backslashes
    _(resolve_app_config(config, "/repo", "/repo/apps/web")).must_equal({ "name" => "web" })
  end
end

describe "resolveScript" do
  include ConfigTestSetup

  def resolve_script(*args) = Portless::Config.resolve_script(*args)

  it "reads script from package.json" do
    write_json(File.join(@tmp_dir, "package.json"), { scripts: { dev: "next dev" } })
    _(resolve_script("dev", @tmp_dir)).must_equal %w[next dev]
  end

  it "returns null for missing script" do
    write_json(File.join(@tmp_dir, "package.json"), { scripts: { build: "next build" } })
    _(resolve_script("dev", @tmp_dir)).must_be_nil
  end

  it "returns null for missing package.json" do
    _(resolve_script("dev", @tmp_dir)).must_be_nil
  end

  it "returns null for empty script value" do
    write_json(File.join(@tmp_dir, "package.json"), { scripts: { dev: "" } })
    _(resolve_script("dev", @tmp_dir)).must_be_nil
  end

  it "splits multi-word script into args" do
    write_json(File.join(@tmp_dir, "package.json"), { scripts: { dev: "NODE_ENV=development next dev --turbo" } })
    _(resolve_script("dev", @tmp_dir)).must_equal [ "NODE_ENV=development", "next", "dev", "--turbo" ]
  end
end

describe "hasScript" do
  include ConfigTestSetup

  def has_script(*args) = Portless::Config.script?(*args)

  it "returns true when script exists" do
    write_json(File.join(@tmp_dir, "package.json"), { scripts: { dev: "next dev" } })
    _(has_script("dev", @tmp_dir)).must_equal true
  end

  it "returns false when script is missing" do
    write_json(File.join(@tmp_dir, "package.json"), { scripts: { build: "next build" } })
    _(has_script("dev", @tmp_dir)).must_equal false
  end

  it "returns false when package.json is missing" do
    _(has_script("dev", @tmp_dir)).must_equal false
  end

  it "returns false when scripts object is missing" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test" })
    _(has_script("dev", @tmp_dir)).must_equal false
  end
end

describe "loadPackagePortlessConfig" do
  include ConfigTestSetup

  def load_package_portless_config(dir) = Portless::Config.load_package_portless_config(dir)

  it "returns config from package.json portless key" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", portless: { name: "myapp", script: "start" } })
    _(load_package_portless_config(@tmp_dir)).must_equal({ "name" => "myapp", "script" => "start" })
  end

  it "returns config from string shorthand" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", portless: "myapp" })
    _(load_package_portless_config(@tmp_dir)).must_equal({ "name" => "myapp" })
  end

  it "returns null for empty string shorthand" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", portless: "" })
    _(load_package_portless_config(@tmp_dir)).must_be_nil
  end

  it "returns null when no portless key" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test" })
    _(load_package_portless_config(@tmp_dir)).must_be_nil
  end

  it "returns null when no package.json" do
    _(load_package_portless_config(@tmp_dir)).must_be_nil
  end

  it "throws ConfigValidationError for invalid portless config" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", portless: { appPort: "bad" } })
    _ { load_package_portless_config(@tmp_dir) }.must_raise Portless::ConfigValidationError
  end
end

describe "isServerCommand" do
  def server_command?(args) = Portless::Config.server_command?(args)

  it "returns true for web server commands" do
    _(server_command?(%w[next dev])).must_equal true
    _(server_command?(%w[vite])).must_equal true
    _(server_command?(%w[node server.js])).must_equal true
    _(server_command?(%w[remix dev])).must_equal true
  end

  it "returns false for build-only commands" do
    _(server_command?(%w[tsup --watch])).must_equal false
    _(server_command?(%w[tsc --watch])).must_equal false
    _(server_command?(%w[esbuild src/index.ts])).must_equal false
    _(server_command?(%w[rollup -c -w])).must_equal false
    _(server_command?(%w[swc src -d dist -w])).must_equal false
    _(server_command?(%w[unbuild])).must_equal false
  end

  it "returns false for empty args" do
    _(server_command?([])).must_equal false
  end
end

describe "detectPackageManager" do
  include ConfigTestSetup

  def detect_package_manager(dir) = Portless::Config.detect_package_manager(dir)

  it "detects pnpm from pnpm-lock.yaml" do
    write(File.join(@tmp_dir, "pnpm-lock.yaml"), "")
    _(detect_package_manager(@tmp_dir)).must_equal "pnpm"
  end

  it "detects yarn from yarn.lock" do
    write(File.join(@tmp_dir, "yarn.lock"), "")
    _(detect_package_manager(@tmp_dir)).must_equal "yarn"
  end

  it "detects bun from bun.lockb" do
    write(File.join(@tmp_dir, "bun.lockb"), "")
    _(detect_package_manager(@tmp_dir)).must_equal "bun"
  end

  it "detects npm from package-lock.json" do
    write(File.join(@tmp_dir, "package-lock.json"), "{}")
    _(detect_package_manager(@tmp_dir)).must_equal "npm"
  end

  it "reads packageManager field from package.json" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", packageManager: "pnpm@11.1.3" })
    _(detect_package_manager(@tmp_dir)).must_equal "pnpm"
  end

  it "prefers packageManager field over lock file" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test", packageManager: "yarn@4.0.0" })
    write(File.join(@tmp_dir, "pnpm-lock.yaml"), "")
    _(detect_package_manager(@tmp_dir)).must_equal "yarn"
  end

  it "walks up to find lock file in parent" do
    write(File.join(@tmp_dir, "pnpm-lock.yaml"), "")
    sub_dir = File.join(@tmp_dir, "packages", "web")
    FileUtils.mkdir_p(sub_dir)
    _(detect_package_manager(sub_dir)).must_equal "pnpm"
  end

  it "defaults to npm when nothing found" do
    _(detect_package_manager(@tmp_dir)).must_equal "npm"
  end
end

describe "resolveScriptCommand" do
  include ConfigTestSetup

  def resolve_script_command(*args) = Portless::Config.resolve_script_command(*args)

  it "returns PM-delegated command when script exists" do
    write(File.join(@tmp_dir, "pnpm-lock.yaml"), "")
    write_json(File.join(@tmp_dir, "package.json"), { scripts: { dev: "next dev" } })
    _(resolve_script_command("dev", @tmp_dir)).must_equal %w[pnpm run dev]
  end

  it "returns null when script is missing" do
    write(File.join(@tmp_dir, "pnpm-lock.yaml"), "")
    write_json(File.join(@tmp_dir, "package.json"), { scripts: { build: "next build" } })
    _(resolve_script_command("dev", @tmp_dir)).must_be_nil
  end

  it "returns null when package.json is missing" do
    _(resolve_script_command("dev", @tmp_dir)).must_be_nil
  end

  it "uses detected package manager" do
    write(File.join(@tmp_dir, "yarn.lock"), "")
    write_json(File.join(@tmp_dir, "package.json"), { scripts: { dev: "next dev" } })
    _(resolve_script_command("dev", @tmp_dir)).must_equal %w[yarn run dev]
  end
end

describe "scriptRunCommand" do
  include ConfigTestSetup

  def script_run_command(*args) = Portless::Config.script_run_command(*args)

  it "keeps a leading literal -- for npm, pnpm, and bun" do
    _(script_run_command("npm", "dev", @tmp_dir, [ "--", "--inspect" ])).must_equal(
      [ "npm", "run", "dev", "--", "--", "--inspect" ]
    )
    _(script_run_command("pnpm", "dev", @tmp_dir, [ "--", "--inspect" ])).must_equal(
      [ "pnpm", "run", "dev", "--", "--inspect" ]
    )
    _(script_run_command("bun", "dev", @tmp_dir, [ "--", "--inspect" ])).must_equal(
      [ "bun", "run", "dev", "--", "--", "--inspect" ]
    )
  end

  it "adds a separator for Yarn Classic but not Berry" do
    write_json(File.join(@tmp_dir, "package.json"), { packageManager: "yarn@1.22.22" })
    _(script_run_command("yarn", "dev", @tmp_dir, [ "--", "--inspect" ])).must_equal(
      [ "yarn", "run", "dev", "--", "--", "--inspect" ]
    )

    write_json(File.join(@tmp_dir, "package.json"), { packageManager: "yarn@4.18.1" })
    _(script_run_command("yarn", "dev", @tmp_dir, [ "--", "--inspect" ])).must_equal(
      [ "yarn", "run", "dev", "--", "--inspect" ]
    )
  end

  it "keeps Yarn exec arguments after its own separator" do
    _(Portless::Config.package_manager_exec("yarn", [ "turbo", "run", "dev", "--", "--inspect" ])).must_equal(
      [ "yarn", "exec", "--", "turbo", "run", "dev", "--", "--inspect" ]
    )
    _(Portless::Config.package_manager_exec("pnpm", [ "turbo", "run", "dev", "--", "--inspect" ])).must_equal(
      [ "pnpm", "exec", "turbo", "run", "dev", "--", "--inspect" ]
    )
  end
end

describe "isYarnClassic" do
  include ConfigTestSetup

  def yarn_classic?(dir) = Portless::Config.yarn_classic?(dir)

  it "reads the packageManager field and lockfile format" do
    write_json(File.join(@tmp_dir, "package.json"), { packageManager: "yarn@4.18.1" })
    _(yarn_classic?(@tmp_dir)).must_equal false

    write_json(File.join(@tmp_dir, "package.json"), { packageManager: "yarn@1.22.22" })
    _(yarn_classic?(@tmp_dir)).must_equal true

    write(File.join(@tmp_dir, "package.json"), "{}")
    write(
      File.join(@tmp_dir, "yarn.lock"),
      "# THIS IS AN AUTOGENERATED FILE. DO NOT EDIT THIS FILE DIRECTLY.\n# yarn lockfile v1\n"
    )
    _(yarn_classic?(@tmp_dir)).must_equal true

    write(File.join(@tmp_dir, "yarn.lock"), "__metadata:\n  version: 8\n")
    _(yarn_classic?(@tmp_dir)).must_equal false
  end

  it "walks up from a workspace package to the root metadata" do
    package_dir = File.join(@tmp_dir, "packages", "web")
    FileUtils.mkdir_p(package_dir)
    write_json(File.join(@tmp_dir, "package.json"), { packageManager: "yarn@1.22.22" })
    _(yarn_classic?(package_dir)).must_equal true
  end
end
