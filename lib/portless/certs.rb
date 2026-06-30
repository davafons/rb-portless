# frozen_string_literal: true

require "openssl"
require "fileutils"

module Portless
  # Local CA + per-host leaf certs, all in native Ruby OpenSSL (portless shells
  # out to the openssl binary; we don't have to). Because *.localhost wildcard
  # certs aren't honoured at the reserved-TLD boundary, every SNI hostname gets
  # its own leaf, minted on demand and cached on disk + in memory.
  class Certs
    CA_SUBJECT = "/CN=portless-rb Local CA"
    CA_DAYS = 3650
    LEAF_DAYS = 365
    CURVE = "prime256v1"

    def initialize
      @leaves = {} # hostname => [cert, key]
    end

    # The CA certificate (PEM-loaded), generating + persisting one on first use.
    def ca_certificate
      @ca_certificate ||= begin
        ensure_ca!
        OpenSSL::X509::Certificate.new(File.read(State.ca_cert))
      end
    end

    def ca_key
      @ca_key ||= begin
        ensure_ca!
        OpenSSL::PKey.read(File.read(State.ca_key))
      end
    end

    # SHA-256 fingerprint — used by the trust marker + OS trust check.
    def ca_fingerprint
      OpenSSL::Digest::SHA256.hexdigest(ca_certificate.to_der)
    end

    # [cert, key] for an SNI hostname. Cached in memory; persisted under
    # host-certs/ so a proxy restart doesn't re-mint everything.
    def leaf_for(hostname)
      hostname = hostname.to_s.downcase
      @leaves[hostname] ||= load_leaf(hostname) || generate_leaf(hostname)
    end

    def ensure_ca!
      return if File.exist?(State.ca_cert) && File.exist?(State.ca_key)

      State.ensure_dir!
      key = OpenSSL::PKey::EC.generate(CURVE)
      cert = OpenSSL::X509::Certificate.new
      name = OpenSSL::X509::Name.parse(CA_SUBJECT)
      cert.version = 2
      cert.serial = random_serial
      cert.subject = name
      cert.issuer = name
      cert.public_key = ec_public(key)
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + CA_DAYS * 86_400

      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = cert
      ef.issuer_certificate = cert
      cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(ef.create_extension("keyUsage", "keyCertSign,cRLSign", true))
      cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash"))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))

      write_secret(State.ca_key, key.to_pem)
      File.write(State.ca_cert, cert.to_pem)
      State.fix_ownership
    end

    private

    def generate_leaf(hostname)
      key = OpenSSL::PKey::EC.generate(CURVE)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = random_serial
      cert.subject = OpenSSL::X509::Name.new([ [ "CN", hostname ] ])
      cert.issuer = ca_certificate.subject
      cert.public_key = ec_public(key)
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + LEAF_DAYS * 86_400

      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = cert
      ef.issuer_certificate = ca_certificate
      cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE", true))
      cert.add_extension(ef.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
      cert.add_extension(ef.create_extension("extendedKeyUsage", "serverAuth"))
      cert.add_extension(ef.create_extension("subjectAltName", san_for(hostname)))
      cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash"))
      cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))

      persist_leaf(hostname, cert, key)
      [ cert, key ]
    end

    # The exact host plus a same-level wildcard (so api.x and x both verify when
    # one is reached via the other).
    def san_for(hostname)
      sans = [ "DNS:#{hostname}" ]
      parts = hostname.split(".")
      sans << "DNS:*.#{parts[1..].join('.')}" if parts.length > 2
      sans.join(",")
    end

    def load_leaf(hostname)
      cert_path, key_path = leaf_paths(hostname)
      return unless File.exist?(cert_path) && File.exist?(key_path)

      cert = OpenSSL::X509::Certificate.new(File.read(cert_path))
      return if cert.not_after < Time.now + 7 * 86_400 # expiring soon → re-mint

      [ cert, OpenSSL::PKey.read(File.read(key_path)) ]
    rescue StandardError
      nil
    end

    def persist_leaf(hostname, cert, key)
      cert_path, key_path = leaf_paths(hostname)
      FileUtils.mkdir_p(State.host_certs_dir)
      File.write(cert_path, cert.to_pem)
      write_secret(key_path, key.to_pem)
      State.fix_ownership(State.host_certs_dir)
    end

    def leaf_paths(hostname)
      safe = hostname.gsub(/[^a-z0-9.-]/, "_")
      [ File.join(State.host_certs_dir, "#{safe}.pem"), File.join(State.host_certs_dir, "#{safe}-key.pem") ]
    end

    # EC public-only key for embedding in a cert. The `public_key=` setter is
    # gone in OpenSSL 3, so round-trip through the public PEM.
    def ec_public(key)
      OpenSSL::PKey.read(key.public_to_pem)
    end

    def random_serial = OpenSSL::BN.rand(159)

    def write_secret(path, pem)
      File.write(path, pem)
      File.chmod(0o600, path)
    end
  end
end
