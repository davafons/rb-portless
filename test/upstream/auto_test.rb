# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/config"
require "open3"

# Mirror of packages/portless/src/auto.test.ts

# ---------------------------------------------------------------------------
# sanitizeForHostname
# ---------------------------------------------------------------------------

describe "sanitizeForHostname" do
  def sanitize(name) = Portless::Auto.sanitize_for_hostname(name)

  it "lowercases input" do
    _(sanitize("MyApp")).must_equal "myapp"
  end

  it "replaces invalid characters with hyphens" do
    _(sanitize("my_app")).must_equal "my-app"
    _(sanitize("my app")).must_equal "my-app"
  end

  it "collapses consecutive hyphens" do
    _(sanitize("my--app")).must_equal "my-app"
    _(sanitize("a___b")).must_equal "a-b"
  end

  it "trims leading and trailing hyphens" do
    _(sanitize("-myapp-")).must_equal "myapp"
    _(sanitize("--myapp--")).must_equal "myapp"
    _(sanitize("@myapp!")).must_equal "myapp"
  end

  it "returns empty string for entirely invalid input" do
    _(sanitize("@@@")).must_equal ""
    _(sanitize("---")).must_equal ""
    _(sanitize("")).must_equal ""
  end

  it "preserves valid characters" do
    _(sanitize("my-app-123")).must_equal "my-app-123"
  end

  it "handles mixed case and underscores" do
    _(sanitize("My_Feature_Branch")).must_equal "my-feature-branch"
  end

  it "truncates labels exceeding 63 characters" do
    _(sanitize("a" * 80).length).must_be :<=, 63
  end

  it "returns deterministic result for truncated labels" do
    long_name = "a" * 80
    _(sanitize(long_name)).must_equal sanitize(long_name)
  end

  it "preserves labels at exactly 63 characters" do
    name63 = "a" * 63
    _(sanitize(name63)).must_equal name63
  end
end

# ---------------------------------------------------------------------------
# truncateLabel
# ---------------------------------------------------------------------------

describe "truncateLabel" do
  def truncate(label) = Portless::Auto.truncate_label(label)

  it "returns label unchanged when <= 63 characters" do
    _(truncate("my-app")).must_equal "my-app"
    _(truncate("a" * 63)).must_equal "a" * 63
  end

  it "truncates label exceeding 63 characters" do
    _(truncate("a" * 80).length).must_be :<=, 63
  end

  it "appends a hash suffix for uniqueness" do
    _(truncate("a" * 80)).must_match(/-[a-f0-9]{6}\z/)
  end

  it "produces different hashes for different inputs" do
    _(truncate("a" * 80)).wont_equal truncate("b" * 80)
  end

  it "is deterministic" do
    input = "my-very-long-feature-branch-name-that-exceeds-the-dns-label-limit-by-quite-a-bit"
    _(truncate(input)).must_equal truncate(input)
  end

  it "does not end with a hyphen before the hash" do
    # Construct input where truncation point falls on a hyphen
    input = "#{'a' * 55}-#{'b' * 20}"
    result = truncate(input)
    _(result.length).must_be :<=, 63
    # Should not have double hyphens from trailing-hyphen stripping + hash separator
    _(result).wont_match(/--/)
  end
end

# ---------------------------------------------------------------------------
# inferProjectName
# ---------------------------------------------------------------------------

describe "inferProjectName" do
  include UpstreamConfigSupport

  before { @tmp_dir = create_tmp_dir("portless-test-") }
  after { cleanup_dir(@tmp_dir) }

  def infer(dir) = Portless::Auto.infer_project_name(dir)

  it "reads name from package.json" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "my-cool-app" })
    result = infer(@tmp_dir)
    _(result.name).must_equal "my-cool-app"
    _(result.source).must_equal "package.json"
  end

  it "strips scoped package name prefix" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "@org/myapp" })
    result = infer(@tmp_dir)
    _(result.name).must_equal "myapp"
    _(result.source).must_equal "package.json"
  end

  it "walks up directories to find package.json" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "parent-app" })
    sub_dir = File.join(@tmp_dir, "src", "components")
    FileUtils.mkdir_p(sub_dir)
    result = infer(sub_dir)
    _(result.name).must_equal "parent-app"
    _(result.source).must_equal "package.json"
  end

  it "skips package.json with empty name" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "" })
    _(infer(@tmp_dir).source).wont_equal "package.json"
  end

  it "skips package.json without name field" do
    write_json(File.join(@tmp_dir, "package.json"), { version: "1.0.0" })
    _(infer(@tmp_dir).source).wont_equal "package.json"
  end

  it "falls back to git root directory name" do
    Dir.mkdir(File.join(@tmp_dir, ".git"))
    result = infer(@tmp_dir)
    _(result.source).must_equal "git root"
    _(result.name).wont_be_empty
  end

  it "falls back to cwd basename" do
    named_dir = File.join(@tmp_dir, "my-project")
    Dir.mkdir(named_dir)
    result = infer(named_dir)
    _(result.name).must_equal "my-project"
    _(result.source).must_equal "directory name"
  end

  it "sanitizes the package.json name" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "My_App" })
    _(infer(@tmp_dir).name).must_equal "my-app"
  end

  it "skips package.json whose name sanitizes to empty" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "@@@" })
    _(infer(@tmp_dir).source).wont_equal "package.json"
  end
end

# Shared by both detectWorktreePrefix describes: a fresh temp dir and an
# unset PORTLESS_PREFIX (vi.stubEnv / vi.unstubAllEnvs).
module AutoWorktreeSetup
  include UpstreamConfigSupport

  def setup
    super
    @tmp_dir = create_tmp_dir(self.class.tmp_prefix)
    @original_prefix = ENV.fetch("PORTLESS_PREFIX", nil)
    ENV.delete("PORTLESS_PREFIX")
  end

  def teardown
    cleanup_dir(@tmp_dir)
    ENV["PORTLESS_PREFIX"] = @original_prefix
    super
  end

  def detect(*args) = Portless::Auto.detect_worktree_prefix(*args)

  def worktree(prefix, source) = Portless::Auto::WorktreePrefix.new(prefix, source)
end

# ---------------------------------------------------------------------------
# detectWorktreePrefix
# ---------------------------------------------------------------------------

describe "detectWorktreePrefix" do
  def self.tmp_prefix = "portless-test-"
  include AutoWorktreeSetup

  # These tests exercise the filesystem-based fallback path. The git CLI
  # fails naturally in temp dirs outside any real git repo.

  # Set up a fake worktree: a .git file pointing to a gitdir, and a HEAD
  # file inside that gitdir with the given branch ref.
  def setup_worktree(dir, branch)
    worktree_name = "wt"
    gitdir = File.join(@tmp_dir, "fake-bare.git", "worktrees", worktree_name)
    FileUtils.mkdir_p(gitdir)
    File.write(File.join(gitdir, "HEAD"), "ref: refs/heads/#{branch}\n")
    File.write(File.join(dir, ".git"), "gitdir: #{gitdir}\n")
  end

  it "returns null for a main checkout (.git directory)" do
    Dir.mkdir(File.join(@tmp_dir, ".git"))
    _(detect(@tmp_dir)).must_be_nil
  end

  it "uses branch name as prefix from .git file" do
    setup_worktree(@tmp_dir, "feature-auth")
    _(detect(@tmp_dir)).must_equal worktree("feature-auth", "git branch")
  end

  it "returns null when branch is main" do
    setup_worktree(@tmp_dir, "main")
    _(detect(@tmp_dir)).must_be_nil
  end

  it "returns null when branch is master" do
    setup_worktree(@tmp_dir, "master")
    _(detect(@tmp_dir)).must_be_nil
  end

  it "returns null for submodule .git file" do
    gitdir = File.join(@tmp_dir, "fake.git", "modules", "my-submodule")
    FileUtils.mkdir_p(gitdir)
    File.write(File.join(@tmp_dir, ".git"), "gitdir: #{gitdir}\n")
    _(detect(@tmp_dir)).must_be_nil
  end

  it "uses last segment of branch name with slashes" do
    setup_worktree(@tmp_dir, "feature/My_Branch")
    _(detect(@tmp_dir)).must_equal worktree("my-branch", "git branch")
  end

  it "keeps the whole branch name with the branch prefix style" do
    cases = [
      [ "team-a/login", "team-a-login" ],
      [ "team-b/login", "team-b-login" ]
    ]
    cases.each do |branch, expected|
      setup_worktree(@tmp_dir, branch)
      _(detect(@tmp_dir).prefix).must_equal "login"
      _(detect(@tmp_dir, "branch")).must_equal worktree(expected, "git branch")
    end
    ENV["PORTLESS_PREFIX"] = "main"
    _(detect(@tmp_dir)).must_equal worktree("main", "PORTLESS_PREFIX")
    ENV["PORTLESS_PREFIX"] = ""
    _(detect(@tmp_dir, "branch")).must_be_nil
  end

  it "returns null when no .git found at all" do
    _(detect(@tmp_dir)).must_be_nil
  end

  it "walks up directories to find .git file" do
    setup_worktree(@tmp_dir, "deep-feature")
    sub_dir = File.join(@tmp_dir, "src", "lib")
    FileUtils.mkdir_p(sub_dir)
    _(detect(sub_dir)).must_equal worktree("deep-feature", "git branch")
  end

  it "returns null for detached HEAD" do
    worktree_name = "wt"
    gitdir = File.join(@tmp_dir, "fake-bare.git", "worktrees", worktree_name)
    FileUtils.mkdir_p(gitdir)
    File.write(File.join(gitdir, "HEAD"), "abc123def456\n")
    File.write(File.join(@tmp_dir, ".git"), "gitdir: #{gitdir}\n")
    _(detect(@tmp_dir)).must_be_nil
  end

  it "returns null for .git file with no gitdir line" do
    File.write(File.join(@tmp_dir, ".git"), "something unexpected\n")
    _(detect(@tmp_dir)).must_be_nil
  end

  it "uses last segment even when it matches a default branch name" do
    setup_worktree(@tmp_dir, "feature/main")
    _(detect(@tmp_dir)).must_equal worktree("main", "git branch")
  end

  it "uses last segment for feature/master" do
    setup_worktree(@tmp_dir, "feature/master")
    _(detect(@tmp_dir)).must_equal worktree("master", "git branch")
  end

  it "returns null when branch sanitizes to empty" do
    setup_worktree(@tmp_dir, "@@@")
    _(detect(@tmp_dir)).must_be_nil
  end

  it "truncates prefix from a branch name exceeding 63 characters" do
    long_branch = "ctd-1744-improve-visibility-of-later-and-undated-notifications-in"
    _(long_branch.length).must_be :>, 63
    setup_worktree(@tmp_dir, long_branch)
    result = detect(@tmp_dir)
    _(result).wont_be_nil
    _(result.prefix.length).must_be :<=, 63
    _(result.source).must_equal "git branch"
  end

  it "produces a deterministic truncated prefix for a long branch name" do
    long_branch = "ctd-1744-improve-visibility-of-later-and-undated-notifications-in"
    setup_worktree(@tmp_dir, long_branch)
    _(detect(@tmp_dir).prefix).must_equal detect(@tmp_dir).prefix
  end
end

# ---------------------------------------------------------------------------
# detectWorktreePrefix (git CLI path)
# ---------------------------------------------------------------------------

describe "detectWorktreePrefix (git CLI path)" do
  # Also verify git init actually works (may be blocked in sandboxes)
  def self.git_init_works?
    return @git_init_works if defined?(@git_init_works)

    probe = Dir.mktmpdir("portless-git-probe-")
    @git_init_works = begin
      system("git", "init", chdir: probe, out: File::NULL, err: File::NULL) || false
    rescue SystemCallError
      false
    ensure
      FileUtils.rm_rf(probe)
    end
  end

  def self.tmp_prefix = "portless-git-test-"
  include AutoWorktreeSetup

  before { skip "git init not available (sandboxed environment)" unless self.class.git_init_works? }

  # Upstream registers this placeholder only when `git init` fails; here the
  # real tests skip themselves instead, so the placeholder always skips.
  it "git init not available (sandboxed environment)" do
    skip "git init works; the git CLI tests below ran instead"
  end

  def run_git(cwd, args)
    out, status = Open3.capture2("git", *args, chdir: cwd, err: File::NULL)
    raise "git #{args.join(' ')} failed" unless status.success?

    out.strip
  end

  def init_repo_with_commit(repo_dir)
    FileUtils.mkdir_p(repo_dir)
    run_git(repo_dir, [ "init" ])
    run_git(repo_dir, [ "branch", "-M", "main" ])
    run_git(repo_dir, [
      "-c", "user.name=Test",
      "-c", "user.email=t@t",
      "-c", "commit.gpgsign=false",
      "commit", "--allow-empty", "-m", "init"
    ])
  end

  it "returns null for a single worktree (no linked worktrees)" do
    repo = File.join(@tmp_dir, "repo")
    init_repo_with_commit(repo)

    _(detect(repo)).must_be_nil
  end

  it "returns prefix for a linked worktree on a non-default branch" do
    repo = File.join(@tmp_dir, "repo")
    init_repo_with_commit(repo)

    run_git(repo, [ "branch", "feature-auth" ])
    wt_dir = File.join(@tmp_dir, "wt-feature-auth")
    run_git(repo, [ "worktree", "add", wt_dir, "feature-auth" ])

    _(detect(wt_dir)).must_equal worktree("feature-auth", "git branch")
  end

  it "returns null for the primary checkout on main when worktrees exist" do
    repo = File.join(@tmp_dir, "repo")
    init_repo_with_commit(repo)

    run_git(repo, [ "branch", "feature-auth" ])
    wt_dir = File.join(@tmp_dir, "wt-feature-auth")
    run_git(repo, [ "worktree", "add", wt_dir, "feature-auth" ])

    _(detect(repo)).must_be_nil
  end

  it "returns null for root worktree on a feature branch (not a linked worktree)" do
    repo = File.join(@tmp_dir, "repo")
    init_repo_with_commit(repo)

    # Create a linked worktree so worktreeCount > 1
    run_git(repo, [ "branch", "feature-auth" ])
    wt_dir = File.join(@tmp_dir, "wt-feature-auth")
    run_git(repo, [ "worktree", "add", wt_dir, "feature-auth" ])

    # Switch the root worktree to a feature branch
    run_git(repo, [ "checkout", "-b", "feature-other" ])

    # Root worktree on a non-default branch should NOT get a prefix
    _(detect(repo)).must_be_nil
  end

  it "returns last segment as prefix for slash-prefixed branch (feature/main)" do
    repo = File.join(@tmp_dir, "repo")
    init_repo_with_commit(repo)

    run_git(repo, [ "branch", "feature/main" ])
    wt_dir = File.join(@tmp_dir, "wt-feature-main")
    run_git(repo, [ "worktree", "add", wt_dir, "feature/main" ])

    _(detect(wt_dir)).must_equal worktree("main", "git branch")
  end

  it "truncates prefix when branch name exceeds 63 characters" do
    repo = File.join(@tmp_dir, "repo")
    init_repo_with_commit(repo)

    long_branch = "ctd-1744-improve-visibility-of-later-and-undated-notifications-in"
    _(long_branch.length).must_be :>, 63

    run_git(repo, [ "branch", long_branch ])
    wt_dir = File.join(@tmp_dir, "wt-long")
    run_git(repo, [ "worktree", "add", wt_dir, long_branch ])

    result = detect(wt_dir)
    _(result).wont_be_nil
    _(result.prefix.length).must_be :<=, 63
    _(result.source).must_equal "git branch"
  end
end

# ---------------------------------------------------------------------------
# applyWorktreePrefix
# ---------------------------------------------------------------------------

describe "applyWorktreePrefix" do
  def apply(*args) = Portless::Auto.apply_worktree_prefix(*args)

  def worktree(prefix, source) = Portless::Auto::WorktreePrefix.new(prefix, source)

  it "returns the base name unchanged when not in a worktree" do
    _(apply("web.json-render", nil)).must_equal "web.json-render"
  end

  it "prepends the worktree prefix as a subdomain (issue #269)" do
    _(apply("web.json-render", worktree("feature-x", "git branch"))).must_equal "feature-x.web.json-render"
  end

  it "prefixes a single-label base name too" do
    _(apply("api", worktree("feature-x", "git branch"))).must_equal "feature-x.api"
  end

  it "truncates over-long template labels per app and normalizes case" do
    wt = worktree("a" * 63, "git branch")
    web = apply("web", wt, "{worktree}-{name}")
    api = apply("api", wt, "{worktree}-{name}")

    _(web.length).must_equal 63
    _(api.length).must_equal 63
    _(web).wont_equal api
    _(apply("WEB", wt, "{worktree}-{name}")).must_equal web
  end
end
