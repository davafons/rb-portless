# frozen_string_literal: true

require_relative "test_helper"

class CertsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    ENV["PORTLESS_STATE_DIR"] = @dir
    # Constants memoized USER_STATE_DIR at load, so point State at the temp dir.
    Portless::State.define_singleton_method(:dir) { ENV["PORTLESS_STATE_DIR"] }
    @certs = Portless::Certs.new
  end

  def teardown
    Portless::State.singleton_class.send(:remove_method, :dir)
    FileUtils.remove_entry(@dir)
  end

  def test_generates_a_ca
    @certs.ensure_ca!
    ca = @certs.ca_certificate
    assert_equal "/CN=portless-rb Local CA", ca.subject.to_s
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
end
