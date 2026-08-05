# frozen_string_literal: true

require_relative "test_helper"

# The version handshake: `run` compares the running proxy's advertised version
# with the loaded gem's and decides whether to offer a restart (proxy stale),
# nudge a gem update (proxy newer), or do nothing. Pure decision logic — the
# restart/stop mechanics need live processes and are verified manually.
class DaemonTest < Minitest::Test
  def test_an_older_proxy_asks_for_a_restart
    assert_equal :restart, Portless::Daemon.version_action("0.3.1", "0.4.0")
    assert_equal :restart, Portless::Daemon.version_action("0.0.0", "0.4.0") # legacy "1" marker
  end

  def test_a_newer_proxy_means_the_gem_is_stale
    assert_equal :update_gem, Portless::Daemon.version_action("0.5.0", "0.4.0")
  end

  def test_matching_versions_do_nothing
    assert_nil Portless::Daemon.version_action("0.4.0", "0.4.0")
  end

  def test_unreadable_versions_do_nothing
    assert_nil Portless::Daemon.version_action(nil, "0.4.0")
    assert_nil Portless::Daemon.version_action("garbage", "0.4.0")
  end

  def test_tls_restart_defaults_to_https_port
    called = nil
    replace_daemon_method(:stop) { }
    replace_daemon_method(:wait_until_stopped) { |port| called = [ :wait, port ] }
    replace_daemon_method(:start) { |tls:, port:, lan: false| called = [ :start, tls, port ] }

    Portless::Daemon.restart(tls: true)

    assert_equal [ :start, true, Portless::Constants::HTTPS_PORT ], called
  ensure
    restore_daemon_methods
  end

  # A plain restart (no --tls/--no-tls/--lan flags) must preserve the running
  # daemon's recorded modes instead of reverting to the defaults.
  def test_plain_restart_preserves_recorded_modes
    Portless::State.ensure_dir!
    File.write(Portless::State.proxy_tls_file, "0")
    File.write(Portless::State.proxy_lan_file, "1")
    called = nil
    replace_daemon_method(:stop) { }
    replace_daemon_method(:wait_until_stopped) { |_port| nil }
    replace_daemon_method(:start) { |tls:, port:, lan: false| called = [ tls, port, lan ] }

    Portless::Daemon.restart

    assert_equal [ false, Portless::Constants::HTTP_PORT, true ], called
  ensure
    restore_daemon_methods
    [ Portless::State.proxy_tls_file, Portless::State.proxy_lan_file ].each do |f|
      File.delete(f) if File.exist?(f)
    end
  end

  # No terminal + privileged port must fail loudly, not silently move every
  # URL to :1355.
  def test_privileged_start_without_a_terminal_raises
    Portless::Privilege.stub(:interactive?, false) do
      error = assert_raises(Portless::NonInteractiveError) do
        Portless::Daemon.send(:start_privileged, port: 443, tls: true)
      end
      assert_match(/PORTLESS_PORT/, error.message)
    end
  end

  private

  def replace_daemon_method(name, &block)
    @daemon_methods ||= {}
    @daemon_methods[name] ||= Portless::Daemon.method(name)
    Portless::Daemon.define_singleton_method(name, &block)
  end

  def restore_daemon_methods
    @daemon_methods&.each do |name, method|
      Portless::Daemon.define_singleton_method(name, method)
    end
  end
end
