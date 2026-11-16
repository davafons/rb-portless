# frozen_string_literal: true

require "test_helper"
require "digest"

# CA trust (certs.ts isCATrusted / trustCA / untrustCA). Never touches the
# real trust store: only marker and injected-config paths are exercised.
class TrustTest < Minitest::Test
  T = Portless::Trust

  def setup
    @dir = Dir.mktmpdir
    File.chmod(0o755, @dir)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def write_ca(content = "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----\n")
    File.write(File.join(@dir, "ca.pem"), content)
  end

  def test_untrusted_without_ca
    refute T.trusted?(@dir)
    assert_equal({ trusted: false, error: "CA certificate not found. Run rb-portless trust to generate it." },
                 T.trust_ca(@dir))
  end

  def test_marker_fast_path
    write_ca
    T.write_trust_marker(@dir)
    assert_equal Digest::SHA256.hexdigest(File.binread(File.join(@dir, "ca.pem"))), T.read_trust_marker(@dir)
    assert T.trusted?(@dir)
  end

  def test_symlinked_marker_is_ignored
    write_ca
    target = File.join(@dir, "elsewhere")
    File.write(target, Digest::SHA256.hexdigest(File.binread(File.join(@dir, "ca.pem"))))
    File.symlink(target, File.join(@dir, "ca.trusted"))
    assert_nil T.read_trust_marker(@dir)
  end

  def test_trust_refuses_unsafe_state_dir
    write_ca
    File.chmod(0o777, @dir)
    assert_match(/Refusing to trust the CA in .*other users can write to it/, T.trust_ca(@dir)[:error])
  ensure
    File.chmod(0o755, @dir)
  end

  def test_untrust_without_ca_clears_marker
    File.write(File.join(@dir, "ca.trusted"), "x")
    assert_equal({ removed: true }, T.untrust_ca(@dir))
    refute File.exist?(File.join(@dir, "ca.trusted"))
  end

  def test_untrust_linux_removes_matching_anchor_and_refreshes
    write_ca
    anchors = Dir.mktmpdir
    other = Dir.mktmpdir
    FileUtils.cp(File.join(@dir, "ca.pem"), File.join(anchors, "rb-portless-ca.crt"))
    File.write(File.join(other, "rb-portless-ca.crt"), "someone else's CA")
    updates = []
    configs = [ { cert_dir: anchors, update_command: "upd" }, { cert_dir: other, update_command: "upd" } ]
    result = T.untrust_linux(@dir, configs: configs, active_config: configs.first, run_update: ->(c) { updates << c })
    assert_equal({ removed: true }, result)
    assert_equal [ "upd" ], updates
    refute File.exist?(File.join(anchors, "rb-portless-ca.crt"))
    assert File.exist?(File.join(other, "rb-portless-ca.crt")), "never removes a CA that isn't ours"
    refute T.trust_refresh_pending?(@dir)
  ensure
    FileUtils.rm_rf([ anchors, other ].compact)
  end

  def test_untrust_linux_keeps_refresh_pending_when_update_fails
    write_ca
    anchors = Dir.mktmpdir
    FileUtils.cp(File.join(@dir, "ca.pem"), File.join(anchors, "rb-portless-ca.crt"))
    configs = [ { cert_dir: anchors, update_command: "upd" } ]
    result = T.untrust_linux(@dir, configs: configs, active_config: configs.first, run_update: ->(_) { raise "nope" })
    refute result[:removed]
    assert T.trust_refresh_pending?(@dir)
  ensure
    FileUtils.rm_rf(anchors)
  end

  def test_run_kills_the_child_on_timeout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Portless::Error) { T.run!([ "sh", "-c", "echo $$ > #{@dir}/pid; exec sleep 30" ], 0.5) }
    assert_equal "spawnSync sh ETIMEDOUT", error.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    pid = File.read(File.join(@dir, "pid")).to_i
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  def test_run_failure_message_matches_exec_file_sync
    error = assert_raises(Portless::Error) { T.run!([ "sh", "-c", "echo oops >&2; exit 3" ], 5) }
    assert_equal "Command failed: sh -c echo oops >&2; exit 3\noops\n", error.message
    assert_equal "out\n", T.run!([ "echo", "out" ], 5)
  end
end
