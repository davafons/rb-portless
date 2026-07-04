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
end
