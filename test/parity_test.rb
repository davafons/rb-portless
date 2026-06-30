# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# Behaviour brought in line with upstream Vercel portless: --force gating,
# port validation, global-flag stripping, named dispatch, worktree prefixes,
# the PORTLESS=0 bypass, and prune returning what it reaped.
class ParityTest < Minitest::Test
  def setup
    @store = Portless::RouteStore.new
    %w[x.localhost y.localhost].each { |h| @store.remove(h) }
  end

  # ── #1/#2 overwrite is gated behind force ────────────────────────────────
  def test_route_conflict_raises_without_force
    sleeper = spawn("sleep", "30")
    @store.add(hostname: "x.localhost", port: 4000, pid: sleeper)

    err = assert_raises(Portless::RouteConflictError) do
      @store.add(hostname: "x.localhost", port: 4001, pid: Process.pid, force: false)
    end
    assert_match(/--force/, err.message)

    @store.add(hostname: "x.localhost", port: 4001, pid: Process.pid, force: true)
    assert_equal Process.pid, @store.routes.find { _1.hostname == "x.localhost" }.pid
  ensure
    Process.kill("KILL", sleeper) rescue nil
    Process.wait(sleeper) rescue nil
    @store.remove("x.localhost")
  end

  # ── #3 / #8 port validation ──────────────────────────────────────────────
  def test_parse_port_validates_range
    cli = Portless::CLI.new([])
    assert_equal 5432, cli.send(:parse_port!, "5432", "port")
    [ "abc", "0", "70000", "-1" ].each do |bad|
      assert_raises(Portless::Error) { cli.send(:parse_port!, bad, "port") }
    end
  end

  # ── #5 global flags stripped from anywhere before `--` ───────────────────
  def test_parse_run_strips_global_flags_anywhere
    cli = Portless::CLI.new([])
    options, command = cli.send(:parse_run, %w[echo hi --tailscale a --name web --app-port 4321 b])
    assert_equal %w[echo hi a b], command
    assert options[:tailscale]
    assert_equal "web", options[:name]
    assert_equal 4321, options[:app_port]
  end

  def test_parse_run_double_dash_passes_command_verbatim
    cli = Portless::CLI.new([])
    options, command = cli.send(:parse_run, %w[--name web -- npm run dev --force])
    assert_equal "web", options[:name]
    assert_equal %w[npm run dev --force], command # --force after -- is the child's
    refute options[:force]
  end

  # ── #9 prune returns the reaped routes (and keeps aliases) ───────────────
  def test_prune_returns_dead_routes_and_keeps_aliases
    victim = spawn("sleep", "30")
    @store.add(hostname: "x.localhost", port: 4000, pid: victim)
    @store.add(hostname: "y.localhost", port: 5432, pid: 0) # alias, never reaped
    Process.kill("KILL", victim); Process.wait(victim)

    reaped = @store.prune
    assert_equal [ "x.localhost" ], reaped.map(&:hostname)
    assert_equal 4000, reaped.first.port
    assert @store.routes.any? { _1.hostname == "y.localhost" }
  ensure
    @store.remove("y.localhost")
  end

  # ── #10 PORTLESS=0|false|skip bypass ─────────────────────────────────────
  def test_skip_proxy_env
    %w[0 false skip FALSE Skip].each do |v|
      ENV["PORTLESS"] = v
      assert Portless.skip_proxy?, "#{v.inspect} should skip"
    end
    [ "1", "true", "", nil ].each do |v|
      v.nil? ? ENV.delete("PORTLESS") : ENV["PORTLESS"] = v
      refute Portless.skip_proxy?, "#{v.inspect} should not skip"
    end
  ensure
    ENV.delete("PORTLESS")
  end

  # ── #11 worktree branch → prefix ─────────────────────────────────────────
  def test_branch_to_prefix
    assert_nil Portless::Worktree.branch_to_prefix("main")
    assert_nil Portless::Worktree.branch_to_prefix("master")
    assert_nil Portless::Worktree.branch_to_prefix("HEAD")
    assert_nil Portless::Worktree.branch_to_prefix("")
    assert_equal "auth", Portless::Worktree.branch_to_prefix("feature/auth")
    assert_equal "fix-login", Portless::Worktree.branch_to_prefix("bug/Fix_Login")
  end

  # ── alias --remove reports whether it removed an alias ───────────────────
  def test_remove_returns_whether_it_removed
    @store.add(hostname: "x.localhost", port: 5432, pid: 0)
    assert @store.remove("x.localhost", owner_pid: 0)
    refute @store.remove("x.localhost", owner_pid: 0) # already gone → false
    refute @store.remove("never.localhost")
  end

  # ── list shows persisted share URLs ──────────────────────────────────────
  def test_route_persists_share_urls
    @store.add(hostname: "x.localhost", port: 4000, pid: Process.pid,
               tailscale: "https://x.ts.net", ngrok: "https://x.ngrok.app")
    r = @store.routes.find { _1.hostname == "x.localhost" }
    assert_equal "https://x.ts.net", r.tailscale
    assert_equal "https://x.ngrok.app", r.ngrok
  ensure
    @store.remove("x.localhost")
  end

  # ── bare subcommand exits 0; unknown sub-action exits 1 ──────────────────
  def test_bare_subcommand_exits_zero_unknown_exits_one
    assert_equal 0, exit_status_of(%w[proxy])
    assert_equal 0, exit_status_of(%w[hosts --help])
    assert_equal 1, exit_status_of(%w[proxy bogus])
    assert_equal 1, exit_status_of(%w[service bogus])
  end

  def test_hostname_applies_name_override_and_worktree_prefix
    config = Portless::Config.new({ "name" => "shirabe" }, Dir.pwd)
    config.define_singleton_method(:worktree_prefix) { "auth" }

    assert_equal "auth.shirabe.localhost", config.hostname
    assert_equal "auth.api.localhost", config.hostname("api")
    assert_equal "api.localhost", config.hostname("api", worktree: false)
  end

  private

  # Run the CLI capturing its exit status without killing the test process.
  def exit_status_of(argv)
    out, err = $stdout, $stderr
    $stdout = $stderr = StringIO.new
    Portless::CLI.new(argv).run
    0
  rescue SystemExit => e
    e.status
  ensure
    $stdout, $stderr = out, err
  end
end
