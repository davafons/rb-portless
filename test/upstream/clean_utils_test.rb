# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/core"
require "delegate"

# Mirror of packages/portless/src/clean-utils.test.ts
#
# Upstream mocks USER_STATE_DIR and LEGACY_SYSTEM_STATE_DIR to temp paths.
# rb-portless never used upstream's legacy /tmp/portless dir (AGENTS.md "Not
# ported"), so LEGACY_SYSTEM_STATE_DIR here is a temp path the code under test
# never consults; the "left alone" assertions still have to hold.
module CleanUtilsMirror
  include UpstreamCore

  ROOT = File.join(Dir.tmpdir, "portless-clean-defaults-#{Process.pid}")
  LEGACY_SYSTEM_STATE_DIR = File.join(ROOT, "legacy")
  Minitest.after_run { FileUtils.rm_rf(ROOT) }

  CU = Portless::CleanUtils

  def legacy_system_state_dir = LEGACY_SYSTEM_STATE_DIR

  def collect_state_dirs_for_cleanup_with_failures = CU.collect_state_dirs_for_cleanup_with_failures
  def remove_portless_state_files(...) = CU.remove_portless_state_files(...)
  def attempt_ca_trust_removal_for_cleanup(dirs, untrust) = CU.attempt_ca_trust_removal_for_cleanup(dirs, &untrust)
  def find_state_dir_problem(dir) = Portless::State.find_problem(dir)
  def cleanable_state_dir?(dir) = Portless::State.cleanable?(dir)

  # A File::Stat with some fields overridden (Object.assign(stat, {...})).
  class StatOverride < SimpleDelegator
    def initialize(stat, **fields)
      super(stat)
      @fields = fields
    end

    def uid = @fields.fetch(:uid) { __getobj__.uid }
    def mode = @fields.fetch(:mode) { __getobj__.mode }
  end

  def read(path) = File.read(path, encoding: "utf-8")
end

describe "collectStateDirsForCleanupWithFailures" do
  include CleanUtilsMirror

  before { @prev_state = ENV["PORTLESS_STATE_DIR"] }

  after do
    if @prev_state.nil?
      ENV.delete("PORTLESS_STATE_DIR")
    else
      ENV["PORTLESS_STATE_DIR"] = @prev_state
    end
  end

  it "includes PORTLESS_STATE_DIR when the directory exists" do
    tmp = mkdtemp("portless-clean-collect-")
    ENV["PORTLESS_STATE_DIR"] = tmp
    dirs = collect_state_dirs_for_cleanup_with_failures[:dirs]
    assert_includes dirs, File.expand_path(tmp)
    FileUtils.rm_rf(tmp)
  end

  it "resolves a symlinked state directory and cleans its physical target" do
    tmp = mkdtemp("portless-clean-collect-link-")
    target = mkdtemp("portless-clean-collect-target-")
    link = File.join(tmp, "state")
    canonical = File.realpath(target)
    File.symlink(target, link)
    ENV["PORTLESS_STATE_DIR"] = link
    begin
      assert_equal false, cleanable_state_dir?(link)
      dirs = collect_state_dirs_for_cleanup_with_failures[:dirs]
      assert_includes dirs, canonical
      refute_includes dirs, link

      File.write(File.join(canonical, "routes.json"), "[]")
      File.write(File.join(canonical, "keep.txt"), "keep")
      assert_equal [], remove_portless_state_files(canonical)
      assert_equal false, File.exist?(File.join(canonical, "routes.json"))
      assert_equal "keep", read(File.join(canonical, "keep.txt"))
    ensure
      FileUtils.rm_rf(tmp)
      FileUtils.rm_rf(target)
    end
  end

  it "leaves a symlinked legacy system state directory and its target alone" do
    ENV.delete("PORTLESS_STATE_DIR")
    target = mkdtemp("portless-clean-legacy-target-")
    untrust = spy { { removed: true } }
    begin
      File.write(File.join(target, "routes.json"), "[]")
      File.write(File.join(target, "ca.pem"), "certificate")
      Dir.mkdir(File.join(target, "host-certs"))
      File.write(File.join(target, "host-certs", "x.pem"), "x")
      FileUtils.rm_rf(legacy_system_state_dir)
      FileUtils.mkdir_p(File.dirname(legacy_system_state_dir))
      File.symlink(target, legacy_system_state_dir)

      dirs = collect_state_dirs_for_cleanup_with_failures[:dirs]
      dirs.each { |dir| remove_portless_state_files(dir) }
      attempt_ca_trust_removal_for_cleanup(dirs, untrust)

      refute_includes dirs, File.realpath(target)
      refute untrust.called?
      assert_equal "[]", read(File.join(target, "routes.json"))
      assert File.exist?(File.join(target, "ca.pem"))
      assert File.exist?(File.join(target, "host-certs", "x.pem"))
    ensure
      FileUtils.rm_rf(legacy_system_state_dir)
      FileUtils.rm_rf(target)
    end
  end

  it "reports an existing configured path that is not a directory" do
    tmp = mkdtemp("portless-clean-collect-file-")
    configured = File.join(tmp, "state")
    File.write(configured, "not a directory")
    ENV["PORTLESS_STATE_DIR"] = configured
    begin
      collected = collect_state_dirs_for_cleanup_with_failures
      refute_includes collected[:dirs], configured
      assert_includes collected[:failures], configured
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "skips a legacy directory owned by another user or writable by others" do
    ENV.delete("PORTLESS_STATE_DIR")
    actual_lstat = File.method(:lstat)
    FileUtils.rm_rf(legacy_system_state_dir)
    FileUtils.mkdir_p(legacy_system_state_dir, mode: 0o755)
    File.chmod(0o755, legacy_system_state_dir)
    canonical = File.realpath(legacy_system_state_dir)
    begin
      foreign = lambda do |target|
        stat = actual_lstat.call(target)
        if [ legacy_system_state_dir, canonical ].include?(target.to_s)
          CleanUtilsMirror::StatOverride.new(stat, uid: Process.uid + 1000)
        else
          stat
        end
      end
      File.stub(:lstat, foreign) do
        assert_equal({ reason: :foreign_owner, path: canonical }, find_state_dir_problem(canonical))
        foreign_collected = collect_state_dirs_for_cleanup_with_failures
        refute_includes foreign_collected[:dirs], canonical
        assert_equal [], foreign_collected[:failures]
      end

      File.chmod(0o777, legacy_system_state_dir)
      assert_equal({ reason: :writable_by_others, path: canonical }, find_state_dir_problem(canonical))
      writable_collected = collect_state_dirs_for_cleanup_with_failures
      refute_includes writable_collected[:dirs], canonical

      File.chmod(0o755, legacy_system_state_dir)
      parent_canonical = File.dirname(canonical)
      unsafe_parent = lambda do |target|
        stat = actual_lstat.call(target)
        if target.to_s == parent_canonical
          CleanUtilsMirror::StatOverride.new(stat, uid: Process.uid + 1000, mode: (stat.mode & ~0o7777) | 0o1777)
        else
          stat
        end
      end
      File.stub(:lstat, unsafe_parent) do
        assert_equal({ reason: :unsafe_parent, path: parent_canonical }, find_state_dir_problem(canonical))
      end
    ensure
      FileUtils.rm_rf(legacy_system_state_dir)
    end
  end
end

describe "removePortlessStateFiles" do
  include CleanUtilsMirror

  before { @tmp_dir = mkdtemp("portless-clean-rm-") }
  after { FileUtils.rm_rf(@tmp_dir) }

  def at(*parts) = File.join(@tmp_dir, *parts)

  it "removes allowlisted files and host-certs directory" do
    File.write(at("routes.json"), "[]")
    File.write(at("ca.pem"), "pem")
    File.write(at("ca.trusted"), "fingerprint")
    File.write(at("ca.trust-refresh-pending"), "1")
    File.write(at("proxy.port"), "443")
    File.write(at("proxy.start"), "1234")
    File.write(at("proxy.start.tmp"), "1234")
    File.write(at("proxy.custom-cert"), "1")
    File.write(at("proxy.tlds"), "localhost\ntest\n")
    File.write(at("proxy.hosts-sync-token"), "token")
    File.write(at("proxy.hosts-sync-token.tmp"), "token")
    Dir.mkdir(at("host-certs"))
    File.write(at("host-certs", "x.pem"), "x")

    File.write(at("user-notes.txt"), "keep me")

    remove_portless_state_files(@tmp_dir)

    assert_equal false, File.exist?(at("routes.json"))
    assert_equal false, File.exist?(at("ca.pem"))
    assert_equal false, File.exist?(at("ca.trusted"))
    assert_equal false, File.exist?(at("ca.trust-refresh-pending"))
    assert_equal false, File.exist?(at("proxy.custom-cert"))
    assert_equal false, File.exist?(at("proxy.start"))
    assert_equal false, File.exist?(at("proxy.start.tmp"))
    assert_equal false, File.exist?(at("proxy.tlds"))
    assert_equal false, File.exist?(at("proxy.hosts-sync-token"))
    assert_equal false, File.exist?(at("proxy.hosts-sync-token.tmp"))
    assert_equal false, File.exist?(at("host-certs"))
    assert_equal "keep me", read(at("user-notes.txt"))
  end

  it "does not throw when paths are missing" do
    remove_portless_state_files(@tmp_dir)
  end

  it "preserves proxy runtime files while the proxy still owns them" do
    File.write(at("proxy.pid"), "123")
    File.write(at("proxy.port"), "443")
    File.write(at("proxy.start"), "1234")
    File.write(at("proxy.log"), "log")
    File.write(at("proxy.tls"), "1")
    File.write(at("proxy.custom-cert"), "1")
    File.write(at("proxy.tld"), "localhost")
    File.write(at("proxy.tlds"), "localhost\ntest\n")
    File.write(at("proxy.lan"), "192.0.2.10")
    File.write(at("routes.json"), "[]")

    remove_portless_state_files(@tmp_dir, preserve_proxy_runtime: true)

    assert_equal true, File.exist?(at("proxy.pid"))
    assert_equal true, File.exist?(at("proxy.port"))
    assert_equal true, File.exist?(at("proxy.start"))
    assert_equal true, File.exist?(at("proxy.log"))
    assert_equal true, File.exist?(at("proxy.tls"))
    assert_equal true, File.exist?(at("proxy.custom-cert"))
    assert_equal true, File.exist?(at("proxy.tld"))
    assert_equal true, File.exist?(at("proxy.tlds"))
    assert_equal true, File.exist?(at("proxy.lan"))
    assert_equal false, File.exist?(at("routes.json"))
  end

  it "refuses a symlinked state directory" do
    target = mkdtemp("portless-clean-target-")
    link = at("state-link")
    File.write(File.join(target, "routes.json"), "[]")
    File.symlink(target, link)
    begin
      assert_equal [ link ], remove_portless_state_files(link)
      assert_equal true, File.exist?(File.join(target, "routes.json"))
    ensure
      FileUtils.rm_rf(target)
    end
  end

  it "removes a host-certs symlink without touching its target" do
    target = mkdtemp("portless-clean-host-certs-")
    link = at("host-certs")
    File.write(File.join(target, "outside.pem"), "keep")
    File.symlink(target, link)
    begin
      assert_equal [], remove_portless_state_files(@tmp_dir)
      assert_equal false, File.exist?(link)
      assert_equal "keep", read(File.join(target, "outside.pem"))
    ensure
      FileUtils.rm_rf(target)
    end
  end

  it "retains the CA identity when trust removal must be retried" do
    File.write(at("routes.json"), "[]")
    File.write(at("ca.pem"), "certificate")
    File.write(at("ca-key.pem"), "private key")
    File.write(at("ca.trusted"), "stale marker")
    File.write(at("ca.trust-refresh-pending"), "1")
    File.write(at("server.pem"), "server certificate")

    remove_portless_state_files(@tmp_dir, preserve_ca_identity: true)

    assert_equal "certificate", read(at("ca.pem"))
    assert_equal "private key", read(at("ca-key.pem"))
    assert_equal false, File.exist?(at("ca.trusted"))
    assert_equal "1", read(at("ca.trust-refresh-pending"))
    assert_equal false, File.exist?(at("routes.json"))
    assert_equal false, File.exist?(at("server.pem"))
  end
end

describe "attemptCATrustRemovalForCleanup" do
  include CleanUtilsMirror

  it "attempts removal even when only one WSL trust store may contain the CA" do
    tmp_dir = mkdtemp("portless-clean-trust-")
    untrust = spy { { removed: false, error: "Windows CA query failed after Linux trust removal" } }

    begin
      File.write(File.join(tmp_dir, "ca.pem"), "certificate")

      results = attempt_ca_trust_removal_for_cleanup([ tmp_dir ], untrust)

      assert_includes untrust.calls, [ tmp_dir ]
      assert_equal({ removed: false, error: "Windows CA query failed after Linux trust removal" }, results[tmp_dir])
    ensure
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it "reports a statSync EACCES for the CA path without calling untrust" do
    tmp_dir = mkdtemp("portless-clean-trust-eacces-")
    ca_path = File.join(tmp_dir, "ca.pem")
    untrust = spy { { removed: true } }
    actual_stat = File.method(:stat)
    stat_calls = []
    stat_mock = lambda do |file|
      stat_calls << file
      raise Errno::EACCES, file.to_s if file.to_s == ca_path

      actual_stat.call(file)
    end
    begin
      File.write(ca_path, "certificate")

      results = File.stub(:stat, stat_mock) { attempt_ca_trust_removal_for_cleanup([ tmp_dir ], untrust) }

      assert_includes stat_calls, ca_path
      refute untrust.called?
      assert_equal false, results[tmp_dir][:removed]
      assert_includes results[tmp_dir][:error], "Could not inspect CA certificate"
    ensure
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it "reports a real unreadable CA path on POSIX" do
    skip "running as root" if Process.uid.zero?
    tmp_dir = mkdtemp("portless-clean-trust-denied-")
    untrust = spy { { removed: true } }
    begin
      File.write(File.join(tmp_dir, "ca.pem"), "certificate")
      File.chmod(0o000, tmp_dir)
      readable = true
      begin
        Dir.children(tmp_dir)
      rescue SystemCallError
        readable = false
      end
      if readable
        File.chmod(0o700, tmp_dir)
        skip "directory still readable"
      end

      results = attempt_ca_trust_removal_for_cleanup([ tmp_dir ], untrust)

      refute untrust.called?
      assert_equal false, results[tmp_dir][:removed]
      assert_includes results[tmp_dir][:error], "Could not inspect CA certificate"
    ensure
      File.chmod(0o700, tmp_dir)
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it "skips a directory when ca.pem is absent" do
    tmp_dir = mkdtemp("portless-clean-trust-missing-")
    untrust = spy { { removed: true } }
    begin
      assert_equal 0, attempt_ca_trust_removal_for_cleanup([ tmp_dir ], untrust).size
      refute untrust.called?
    ensure
      FileUtils.rm_rf(tmp_dir)
    end
  end
end
