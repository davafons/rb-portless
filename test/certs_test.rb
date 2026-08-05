# frozen_string_literal: true

require_relative "test_helper"

class CertsTest < Minitest::Test
  def setup
    @prev_dir = ENV["PORTLESS_STATE_DIR"]
    @dir = Dir.mktmpdir
    ENV["PORTLESS_STATE_DIR"] = @dir # State.dir reads this at call time
    @certs = Portless::Certs.new
  end

  def teardown
    ENV["PORTLESS_STATE_DIR"] = @prev_dir
    FileUtils.remove_entry(@dir)
  end

  def test_generates_a_ca
    @certs.ensure_ca!
    ca = @certs.ca_certificate
    assert_equal "/CN=rb-portless Local CA", ca.subject.to_s
    assert ca.extensions.any? { |e| e.oid == "basicConstraints" && e.value.include?("CA:TRUE") }
  end

  def test_leaf_is_signed_by_ca_with_correct_sans
    cert, = @certs.leaf_for("kobe.shirabe.org.localhost")
    assert_equal "/CN=kobe.shirabe.org.localhost", cert.subject.to_s
    assert cert.verify(@certs.ca_certificate.public_key)

    san = cert.extensions.find { |e| e.oid == "subjectAltName" }.value
    assert_includes san, "DNS:kobe.shirabe.org.localhost"
    assert_includes san, "DNS:*.shirabe.org.localhost"
  end

  def test_leaf_is_cached_in_memory
    a, = @certs.leaf_for("x.localhost")
    b, = @certs.leaf_for("x.localhost")
    assert_same a, b
  end

  def test_fingerprint_is_stable
    @certs.ensure_ca!
    assert_equal @certs.ca_fingerprint, @certs.ca_fingerprint
    assert_match(/\A[0-9a-f]{64}\z/, @certs.ca_fingerprint)
  end

  def test_leaf_is_persisted_and_reloaded_across_instances
    cert, = @certs.leaf_for("persist.localhost")
    reloaded, key = Portless::Certs.new.leaf_for("persist.localhost")
    assert_equal cert.serial, reloaded.serial # same cert from disk, not a re-mint
    assert key
  end

  def test_an_expiring_leaf_is_reminted
    cert, = @certs.leaf_for("expiring.localhost")
    # Rewrite the persisted cert as one that expires within the 7-day buffer.
    soon = OpenSSL::X509::Certificate.new(cert.to_pem)
    soon.not_after = Time.now + 3600
    soon.sign(@certs.ca_key, OpenSSL::Digest.new("SHA256"))
    path = File.join(Portless::State.host_certs_dir, "expiring.localhost.pem")
    File.write(path, soon.to_pem)

    fresh, = Portless::Certs.new.leaf_for("expiring.localhost")
    assert fresh.not_after > Time.now + 8 * 86_400, "expiring leaf was not re-minted"
  end

  def test_two_label_host_gets_no_wildcard_san
    cert, = @certs.leaf_for("myapp.localhost")
    san = cert.extensions.find { |e| e.oid == "subjectAltName" }.value
    assert_includes san, "DNS:myapp.localhost"
    refute_includes san, "*" # *.localhost is invalid at the reserved-TLD boundary
  end
end
