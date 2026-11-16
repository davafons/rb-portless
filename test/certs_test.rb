# frozen_string_literal: true

require_relative "test_helper"

# Ported from upstream certs.test.ts (ensureCerts, createSNICallback,
# sanitizeHostForFilename).
class CertsTest < Minitest::Test
  Certs = Portless::Certs

  def setup
    @dir = Dir.mktmpdir("portless-certs-test-")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def read_cert(name) = OpenSSL::X509::Certificate.new(File.read(File.join(@dir, name)))
  def san(cert) = cert.extensions.find { |e| e.oid == "subjectAltName" }&.value.to_s

  def sni(tlds = "localhost")
    certs = Certs.ensure_certs(@dir)
    Certs.create_sni_callback(@dir, File.read(certs[:cert_path]), File.read(certs[:key_path]), tlds,
                              File.read(certs[:ca_path]))
  end


  def host_cert(hostname)
    OpenSSL::X509::Certificate.new(
      File.read(File.join(@dir, "host-certs", "#{Certs.sanitize_host_for_filename(hostname)}.pem"))
    )
  end

  # sanitizeHostForFilename -------------------------------------------------

  def test_sanitize_keeps_short_hostnames_readable
    assert_equal "myapp_localhost", Certs.sanitize_host_for_filename("myapp.localhost")
  end

  def test_sanitize_bounds_long_names_deterministically_and_distinctly
    long = "#{'a' * 63}.#{'b' * 63}.#{'c' * 63}.#{'d' * 61}"
    safe = Certs.sanitize_host_for_filename(long)
    assert_operator "#{safe}-key.pem".length, :<=, 255
    assert_equal safe, Certs.sanitize_host_for_filename(long)
    refute_equal safe, Certs.sanitize_host_for_filename(long.sub("a", "z"))
  end

  # ensureCerts -------------------------------------------------------------

  def test_generates_ca_and_server_certs_on_first_call
    result = Certs.ensure_certs(@dir)
    assert result[:ca_generated]
    %w[ca.pem ca-key.pem server.pem server-key.pem].each { |f| assert File.exist?(File.join(@dir, f)) }
    assert_equal 0o600, File.stat(File.join(@dir, "ca-key.pem")).mode & 0o777
    assert_equal 0o600, File.stat(File.join(@dir, "server-key.pem")).mode & 0o777
  end

  def test_ca_is_a_strong_backdated_ca
    Certs.ensure_certs(@dir)
    ca = read_cert("ca.pem")
    assert_equal "/CN=rb-portless Local CA", ca.subject.to_s
    assert ca.extensions.any? { |e| e.oid == "basicConstraints" && e.critical? && e.value.include?("CA:TRUE") }
    assert_includes ca.signature_algorithm.downcase, "sha256"
    assert_operator ca.not_before, :<=, Time.now - 4 * 60
    refute Certs.duplicate_extensions?(File.join(@dir, "ca.pem"))
  end

  def test_server_cert_is_signed_by_the_ca_with_default_sans
    Certs.ensure_certs(@dir)
    ca = read_cert("ca.pem")
    server = read_cert("server.pem")
    refute_equal ca.serial, server.serial
    assert server.verify(ca.public_key)
    assert_equal "DNS:localhost, DNS:*.localhost, DNS:*.local", san(server)
    assert_operator server.not_before, :<=, Time.now - 4 * 60
  end

  def test_reuses_existing_certs
    Certs.ensure_certs(@dir)
    before = File.read(File.join(@dir, "server.pem"))
    refute Certs.ensure_certs(@dir)[:ca_generated]
    assert_equal before, File.read(File.join(@dir, "server.pem"))
  end

  def test_regenerates_a_deleted_server_cert
    Certs.ensure_certs(@dir)
    File.delete(File.join(@dir, "server.pem"))
    Certs.ensure_certs(@dir)
    assert File.exist?(File.join(@dir, "server.pem"))
  end

  def test_regenerates_a_server_cert_missing_the_local_san
    Certs.ensure_certs(@dir)
    ca, ca_key = Certs.load_ca(@dir)
    old = Certs.send(:sign_leaf, ca, ca_key, "localhost", %w[DNS:localhost DNS:*.localhost]).first
    File.write(File.join(@dir, "server.pem"), old.to_pem)
    Certs.ensure_certs(@dir)
    assert_includes san(read_cert("server.pem")), "DNS:*.local"
  end

  def test_regenerates_a_sha1_server_cert
    Certs.ensure_certs(@dir)
    ca, ca_key = Certs.load_ca(@dir)
    weak = Certs.send(:sign_leaf, ca, ca_key, "localhost", Certs::SERVER_SANS).first
    weak.sign(ca_key, OpenSSL::Digest.new("SHA1"))
    File.write(File.join(@dir, "server.pem"), weak.to_pem)
    refute Certs.cert_signature_strong?(File.join(@dir, "server.pem"))
    Certs.ensure_certs(@dir)
    assert Certs.cert_signature_strong?(File.join(@dir, "server.pem"))
  end

  def test_regenerates_a_ca_with_duplicate_extensions_and_drops_host_certs
    Certs.ensure_certs(@dir)
    sni.call("app.localhost")
    key = OpenSSL::PKey.read(File.read(File.join(@dir, "ca-key.pem")))
    ca = read_cert("ca.pem")
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = ca
    ca.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
    ca.sign(key, OpenSSL::Digest.new("SHA256"))
    File.write(File.join(@dir, "ca.pem"), ca.to_pem)
    assert Certs.duplicate_extensions?(File.join(@dir, "ca.pem"))

    assert Certs.ensure_certs(@dir)[:ca_generated]
    refute Certs.duplicate_extensions?(File.join(@dir, "ca.pem"))
    refute File.exist?(File.join(@dir, "host-certs"))
  end

  def test_generates_certs_when_the_state_dir_contains_a_dot
    dotted = File.join(@dir, "user.name", "state")
    FileUtils.mkdir_p(dotted)
    Certs.ensure_certs(dotted)
    assert File.exist?(File.join(dotted, "server.pem"))
  end

  # createSNICallback -------------------------------------------------------

  def test_localhost_uses_the_default_context
    callback = sni
    assert_same callback.call("localhost"), callback.call("localhost")
    refute File.exist?(File.join(@dir, "host-certs"))
  end

  def test_single_level_subdomain_gets_an_exact_san_leaf
    sni.call("myapp.localhost")
    cert = host_cert("myapp.localhost")
    assert_equal "DNS:myapp.localhost", san(cert)
    assert cert.verify(read_cert("ca.pem").public_key)
    assert_operator cert.not_before, :<=, Time.now - 4 * 60
  end

  def test_multi_level_subdomain_gets_a_parent_wildcard
    sni.call("chat.myapp.localhost")
    assert_equal "DNS:chat.myapp.localhost, DNS:*.myapp.localhost", san(host_cert("chat.myapp.localhost"))
  end

  def test_multi_segment_tlds
    sni("dev.internal").call("app.dev.internal")
    assert_includes san(host_cert("app.dev.internal")), "DNS:app.dev.internal"
  end

  def test_hostname_longer_than_64_characters_truncates_the_cn
    host = "#{'a' * 70}.localhost"
    sni.call(host)
    cert = host_cert(host)
    assert_equal "a" * 64, cert.subject.to_a.find { |k, _| k == "CN" }[1]
    assert_includes san(cert), "DNS:#{host}"
  end

  def test_caches_contexts_in_memory
    callback = sni
    assert_same callback.call("app.localhost"), callback.call("app.localhost")
  end

  def test_reissues_a_cached_cert_with_a_bare_tld_wildcard
    callback = sni
    ca, ca_key = Certs.load_ca(@dir)
    bad, key = Certs.send(:sign_leaf, ca, ca_key, "app.localhost", %w[DNS:app.localhost DNS:*.localhost])
    FileUtils.mkdir_p(File.join(@dir, "host-certs"))
    File.write(File.join(@dir, "host-certs", "app_localhost.pem"), bad.to_pem)
    File.write(File.join(@dir, "host-certs", "app_localhost-key.pem"), key.to_pem)
    callback.call("app.localhost")
    assert_equal "DNS:app.localhost", san(host_cert("app.localhost"))
  end

  def test_reuses_a_valid_cert_from_disk
    sni.call("app.localhost")
    serial = host_cert("app.localhost").serial
    sni.call("app.localhost")
    assert_equal serial, host_cert("app.localhost").serial
  end

  def test_refuses_hostnames_outside_the_configured_tlds
    callback = sni([ "localhost", "test" ])
    error = assert_raises(Portless::Error) { callback.call("evil.com") }
    assert_includes error.message, "not under a configured TLD"
    assert_raises(Portless::Error) { callback.call("bad_name.localhost") }
    assert_raises(Portless::Error) { callback.call("localhost.evil") }
    refute File.exist?(File.join(@dir, "host-certs"))
    callback.call("ok.test")
    assert File.exist?(File.join(@dir, "host-certs", "ok_test.pem"))
  end

  def test_unreadable_server_key_is_regenerated
    skip "root reads any file" if Process.uid.zero?
    Certs.ensure_certs(@dir)
    key_path = File.join(@dir, "server-key.pem")
    File.chmod(0o000, key_path)
    Certs.ensure_certs(@dir)
    assert File.readable?(key_path), "fileExists requires read access, like certs.ts"
  end

  def test_concurrent_requests_share_one_generation
    callback = sni
    contexts = 4.times.map { Thread.new { callback.call("race.localhost") } }.map(&:value)
    assert_equal 1, contexts.uniq.size
  end
end
