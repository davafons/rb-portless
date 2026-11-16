# frozen_string_literal: true

require_relative "../../e2e_cli_helper"

# Shared harness for the tests/e2e mirrors (upstream tests/e2e/src/harness.ts
# plus the helpers zombie/parallel/self-daemon inline), built on the CLI e2e
# helper: each test gets its own state dir and a free high proxy port, drives
# the real exe/rb-portless, and talks to the proxy with a Host header. Hosts
# sync stays off (PORTLESS_SYNC_HOSTS=0), so nothing touches /etc/hosts.
module UpstreamE2E
  include E2ECli

  # Upstream's tests/e2e checkout (framework fixtures + their node_modules).
  UPSTREAM_E2E = File.expand_path("../../../references/portless/tests/e2e", __dir__)
  E2E_NODE_MODULES = File.join(UPSTREAM_E2E, "node_modules")
  PYTHON_BIN = File.join(UPSTREAM_E2E, ".venv", "bin", "python3")

  # The per-test setup/teardown of the CLI e2e tests (upstream's
  # cleanupTestState). A describe's own before/after blocks run around these.
  def setup
    super
    e2e_setup
  end

  def teardown
    e2e_teardown
    super
  end

  def e2e_setup
    @state_dir = make_state_dir
    @proxy_port = free_port
    @env = env_for(@state_dir, @proxy_port)
    @children = []
    @app_ports = []
  end

  def e2e_teardown
    @children.each do |child|
      next if child.exited?

      child.kill("TERM")
      child.kill("KILL") unless child.wait(1)
      child.wait(2)
    end
    @app_ports.each { |port| kill_port(port) }
    stop_proxy(@env, @proxy_port)
    FileUtils.rm_rf(@state_dir)
    restore_fixture
  end

  # Dev servers rewrite files in the upstream checkout (next dev reformats
  # tsconfig.json and adds AGENTS.md); put the fixture's top-level files back.
  def snapshot_fixture(cwd)
    files = Dir.children(cwd).map { |f| File.join(cwd, f) }.select { |f| File.file?(f) }
    @fixture_snapshot = [ cwd, files.to_h { |f| [ f, File.binread(f) ] } ]
  end

  def restore_fixture
    cwd, files = @fixture_snapshot
    return unless cwd

    files.each { |path, content| File.binwrite(path, content) unless File.exist?(path) && File.binread(path) == content }
    Dir.children(cwd).map { |f| File.join(cwd, f) }.each do |path|
      File.delete(path) if File.file?(path) && !files.key?(path)
    end
  end

  def track(child)
    @children << child
    child
  end

  # harness.ts fixtureDir.
  def fixture_dir(name) = File.join(UPSTREAM_E2E, "fixtures", name)

  # harness.ts resolveBin: the fixture's node_modules/.bin, then the e2e one.
  def resolve_bin(command, cwd)
    [ File.join(cwd, "node_modules", ".bin", command), File.join(E2E_NODE_MODULES, ".bin", command) ]
      .find { |path| File.exist?(path) } || command
  end

  def node? = system("node", "--version", out: File::NULL, err: File::NULL)

  # Whether the fixture's toolchain is installed, so the test can run.
  def toolchain?(command, cwd)
    return false unless Dir.exist?(cwd)
    return File.executable?(command) if command.start_with?("/")
    return node? && Dir.exist?(E2E_NODE_MODULES) if command == "node"

    node? && resolve_bin(command, cwd) != command
  end

  # harness.ts startApp: run `rb-portless <name> <command>` (auto-starting the
  # proxy) and wait until the proxy serves the app. → the CLI child.
  def start_app(name:, command:, cwd:, timeout: 60, env: {})
    skip "fixture toolchain not installed" unless toolchain?(command[0], cwd)

    snapshot_fixture(cwd)
    resolved = [ resolve_bin(command[0], cwd), *command.drop(1) ]
    child = track(spawn_cli(@env.merge("NODE_PATH" => E2E_NODE_MODULES).merge(env), name, *resolved, chdir: cwd))
    hostname = name.include?(".") ? name : "#{name}.localhost"
    ready = wait_for_app(@proxy_port, hostname, timeout: timeout)
    route = read_routes(@state_dir).find { |r| r["hostname"] == hostname }
    @app_ports << route["port"] if route
    raise "App #{hostname} did not become ready within #{timeout}s\n#{child.logs}" unless ready

    child
  end

  # harness.ts-based framework test body: fetch(ctx.proxyUrl), 200 + body.
  def assert_serves(name, expected)
    status, body, = request(@proxy_port, name.include?(".") ? name : "#{name}.localhost", timeout: 30)
    _(status).must_equal 200
    _(body).must_include expected
  end
end
