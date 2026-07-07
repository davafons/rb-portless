# frozen_string_literal: true

require_relative "test_helper"

class CaBundleTest < Minitest::Test
  def setup
    @prev_dir = ENV["PORTLESS_STATE_DIR"]
    @prev_cert_file = ENV["SSL_CERT_FILE"]
    @dir = Dir.mktmpdir
    ENV["PORTLESS_STATE_DIR"] = @dir # State.dir reads this at call time
    ENV.delete("SSL_CERT_FILE")
    Portless::Certs.new.ensure_ca!
  end

  def teardown
    ENV["PORTLESS_STATE_DIR"] = @prev_dir
    @prev_cert_file ? ENV["SSL_CERT_FILE"] = @prev_cert_file : ENV.delete("SSL_CERT_FILE")
    FileUtils.remove_entry(@dir)
  end

  def test_returns_nil_when_ca_missing
    FileUtils.rm_f(Portless::State.ca_cert)
    assert_nil Portless::CaBundle.path
  end

  def test_bundle_carries_both_our_ca_and_the_public_roots
    roots = File.join(@dir, "system-roots.pem")
    File.write(roots, "# SYSTEM ROOT MARKER\n")
    ENV["SSL_CERT_FILE"] = roots # stand in for the OS trust store

    bundle = Portless::CaBundle.path
    contents = File.read(bundle)

    refute_equal roots, bundle, "must not hand back the bare system store"
    assert_includes contents, "SYSTEM ROOT MARKER", "public roots must survive"
    assert_includes contents, File.read(Portless::State.ca_cert).strip, "our CA must be present"
  end

  def test_never_reads_its_own_bundle_as_the_system_store
    # A prior run left SSL_CERT_FILE pointing at our combined bundle; we must not
    # treat that as the system store (it would compound on itself every run).
    first = Portless::CaBundle.path
    ENV["SSL_CERT_FILE"] = first
    refute_equal first, Portless::CaBundle.system_roots
  end

  def test_rebuilds_when_ca_changes
    bundle = Portless::CaBundle.path
    before = File.read(bundle)

    # A newer CA on disk must invalidate the cached bundle.
    future = Time.now + 5
    File.write(Portless::State.ca_cert, "#{File.read(Portless::State.ca_cert)}\n# rotated\n")
    File.utime(future, future, Portless::State.ca_cert)

    assert Portless::CaBundle.stale?(bundle)
    refute_equal before, File.read(Portless::CaBundle.path)
  end
end
