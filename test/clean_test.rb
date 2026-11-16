# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "json"

# `clean` (cli.ts handleClean + clean-utils.ts). Never touches the real
# machine: the hosts file is a temp file, the service/proxy/trust steps are
# stubbed, and sudo is the refusing test shim.
class CleanTest < Minitest::Test
  def setup
    @env = ENV.to_h
    @dir = File.realpath(Dir.mktmpdir("rb-portless-clean"))
    File.chmod(0o755, @dir)
    ENV["PORTLESS_STATE_DIR"] = @dir
    # clean also sweeps ~/.rb-portless: point HOME at an empty temp dir.
    ENV["HOME"] = File.join(@dir, "home")
    @hosts = File.join(@dir, "hosts-file")
    File.write(@hosts, "127.0.0.1 localhost\n\n#{Portless::Hosts::MARKER_START}\n127.0.0.1 a.test\n" \
                       "#{Portless::Hosts::MARKER_END}\n")
    Portless::Hosts.hosts_path = @hosts
  end

  def teardown
    Portless::Hosts.hosts_path = nil
    ENV.replace(@env)
    FileUtils.rm_rf(@dir)
  end

  def state = Portless::Daemon::ProxyState.new(dir: @dir, port: 1, tls: false, tld: "localhost",
                                               tlds: [ "localhost" ], lan_mode: false, lan_ip: nil)

  def clean(stop: true, service: { removed: false, installed: false }, untrust: { removed: true })
    code = nil
    out, err = capture_io do
      Portless::Service.stub(:try_uninstall, service) do
        Portless::Daemon.stub(:discover_state, state) do
          Portless::Daemon.stub(:stop_proxy, stop) do
            Portless::Health.stub(:proxy_running?, false) do
              Portless::Trust.stub(:untrust_ca, ->(_) { untrust }) do
                code = Portless::CLI.new(%w[clean --yes]).main
              end
            end
          end
        end
      end
    end
    [ code, out, err ]
  end

  def test_clean_removes_state_and_hosts_block
    assert_equal File.join(@dir, "home"), File.expand_path(Portless::Constants::DEFAULT_STATE_DIR).sub(%r{/[^/]+\z}, "")
    File.write(File.join(@dir, "routes.json"), "[]")
    File.write(File.join(@dir, "proxy.log"), "x")
    code, out, err = clean
    assert_equal 0, code, err
    assert_includes err, "Remove the rb-portless block from /etc/hosts"
    assert_includes out, "Removed rb-portless entries from /etc/hosts."
    assert_includes out, "Clean finished."
    refute File.exist?(File.join(@dir, "routes.json"))
    refute File.exist?(File.join(@dir, "proxy.log"))
    refute_includes File.read(@hosts), "a.test"
  end

  def write_ca_files
    %w[ca.pem ca-key.pem].each { |f| File.write(File.join(@dir, f), "x") }
    File.write(File.join(@dir, "routes.json"), "[]")
  end

  def run_steps(steps, preserve_proxy_runtime, trusted: false, untrust: { removed: true })
    Portless::Trust.stub(:trusted?, trusted) do
      Portless::Trust.stub(:untrust_ca, ->(_) { untrust }) do
        Portless::CleanUtils.run_cleanup_steps(steps, [ @dir ], preserve_proxy_runtime)
      end
    end
  end

  def test_unconfirmed_proxy_stop_keeps_ca_and_runtime_files
    write_ca_files
    File.write(File.join(@dir, "proxy.pid"), "1")
    outcome = run_steps(%w[files hosts], true)
    assert_empty outcome[:state_failures]
    assert File.exist?(File.join(@dir, "ca.pem"))
    assert File.exist?(File.join(@dir, "ca-key.pem"))
    assert File.exist?(File.join(@dir, "proxy.pid"))
    refute File.exist?(File.join(@dir, "routes.json"))
  end

  def test_still_trusted_ca_keeps_identity_files
    write_ca_files
    run_steps(%w[ca files], false, trusted: true)
    assert File.exist?(File.join(@dir, "ca.pem"))
    refute File.exist?(File.join(@dir, "routes.json"))
  end

  def test_pending_trust_refresh_keeps_identity_files
    write_ca_files
    File.write(File.join(@dir, "ca.trust-refresh-pending"), "")
    run_steps(%w[ca files], false)
    assert File.exist?(File.join(@dir, "ca-key.pem"))
  end

  def test_failed_untrust_keeps_identity_files_and_removed_ca_does_not
    write_ca_files
    outcome = run_steps(%w[ca files], false, untrust: { removed: false, error: "nope" })
    assert_equal [ @dir ], outcome[:failed_ca_state_dirs]
    assert File.exist?(File.join(@dir, "ca.pem"))
    run_steps(%w[ca files], false)
    refute File.exist?(File.join(@dir, "ca.pem"))
  end

  def test_service_uninstall_retry_runs_the_sudo_argv_once
    seen = nil
    run_sudo = lambda do |argv|
      seen = argv
      Portless::Privilege::SpawnResult.new(nil, "spawnSync sudo ENOENT")
    end
    code = out = err = nil
    Portless::Privilege.stub(:root?, false) do
      Portless::Privilege.stub(:run_sudo, run_sudo) do
        code, out, err = clean(service: { removed: false, installed: true, error: "denied", needs_elevation: true })
      end
    end
    assert_equal 1, code
    assert_includes out, "Removing the startup service requires elevated privileges. Requesting sudo..."
    assert_includes err, "Failed to remove startup service with sudo."
    assert_equal Portless::Service.uninstall_sudo_args, seen
    assert_equal 1, seen.count("env")
  end

  def with_sudo(result)
    calls = []
    run_sudo = lambda do |argv|
      calls << argv
      result
    end
    Portless::Privilege.stub(:run_sudo, run_sudo) { yield calls }
  end

  def stuck_routes_file
    stuck = File.join(@dir, "proxy.log")
    FileUtils.mkdir_p(File.join(stuck, "child"))
    stuck
  end

  def test_failed_steps_are_retried_with_sudo_against_the_approved_dirs
    stuck_routes_file
    ok = Portless::Privilege::SpawnResult.new(Struct.new(:exitstatus).new(0), nil)
    with_sudo(ok) do |calls|
      code, out, err = clean
      assert_equal 0, code, err
      assert_includes out, "Cleanup needs elevated privileges. Requesting sudo for state files..."
      argv = calls.last
      assert_equal [ "env", "HOME=#{ENV['HOME']}", "PORTLESS_INTERNAL_CLEAN_STEPS=files",
                     "PORTLESS_INTERNAL_CLEAN_DIRS=#{JSON.generate([ @dir ])}" ], argv.first(4)
      assert_equal %w[clean --yes], argv.last(2)
    end
  end

  def test_failed_sudo_retry_rechecks_without_elevation
    stuck = stuck_routes_file
    with_sudo(Portless::Privilege::SpawnResult.new(nil, "spawnSync sudo ETIMEDOUT")) do
      code, _, err = clean
      assert_equal 1, code
      assert_includes err, "Could not run sudo: spawnSync sudo ETIMEDOUT"
      assert_includes err, "Could not remove state file: #{stuck}"
    end
  end

  def test_failed_ca_removal_is_cleared_when_the_ca_is_no_longer_trusted
    write_ca_files
    with_sudo(Portless::Privilege::SpawnResult.new(nil, "spawnSync sudo ENOENT")) do |calls|
      code, out, err = Portless::Trust.stub(:trusted?, false) { clean(untrust: { removed: false, error: "denied" }) }
      assert_equal 0, code, err
      assert_match(/PORTLESS_INTERNAL_CLEAN_STEPS=ca,files/, calls.last.join(" "))
      assert_includes out, "Removed local CA from the system trust store."
      refute File.exist?(File.join(@dir, "ca.pem"))
    end
  end

  def test_elevated_reentry_runs_only_the_requested_steps
    write_ca_files
    ENV["PORTLESS_INTERNAL_CLEAN_STEPS"] = "files"
    ENV["PORTLESS_INTERNAL_CLEAN_DIRS"] = JSON.generate([ @dir ])
    capture_io { assert_equal 2, Portless::CLI.new(%w[clean]).main }
    code = nil
    out, err = capture_io { code = Portless::CLI.new(%w[clean --yes]).main }
    assert_equal 0, code
    assert_empty out + err
    refute File.exist?(File.join(@dir, "routes.json"))
    assert_includes File.read(@hosts), "a.test", "hosts step was not requested"
  end

  def test_elevated_reentry_rejects_unapproved_input
    assert_raises(Portless::Error) { Portless::CleanUtils.parse_cleanup_steps("files,rm") }
    assert_equal %w[ca hosts], Portless::CleanUtils.parse_cleanup_steps(" hosts , ca ")
    assert_nil Portless::CleanUtils.parse_cleanup_steps(" ")
    assert_raises(Portless::Error) { Portless::CleanUtils.parse_cleanup_dirs('["relative"]') }
    assert_equal [ "/a" ], Portless::CleanUtils.parse_cleanup_dirs('["/a","/a"]')
  end
end
