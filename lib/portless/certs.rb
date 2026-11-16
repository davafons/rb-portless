# frozen_string_literal: true

require "openssl"
require "fileutils"
require "digest"

module Portless
  # Local CA, the default server cert and per-host leaf certs. Upstream
  # (certs.ts) shells out to the openssl binary; the Ruby equivalent is the
  # OpenSSL extension, so every cert here is built in-process with the same
  # subjects, extensions, validity and regeneration rules.
  #
  # `*.localhost` wildcards are not honoured at the reserved-TLD boundary, so
  # every SNI hostname under a configured TLD gets its own leaf, minted on
  # demand and cached on disk + in memory.
  class Certs
    CA_VALIDITY_DAYS = 3650
    SERVER_VALIDITY_DAYS = 365
    EXPIRY_BUFFER = 7 * 24 * 60 * 60 # regenerate certs expiring within 7 days
    # Upstream: "portless Local CA". Ours differs so both CAs can be trusted side by side.
    CA_COMMON_NAME = "rb-portless Local CA"
    CA_SUBJECT = "/CN=#{CA_COMMON_NAME}".freeze
    # Backdate notBefore so a client whose clock runs slightly behind accepts a fresh cert.
    NOT_BEFORE_SKEW = 5 * 60
    CURVE = "prime256v1"

    CA_KEY_FILE = "ca-key.pem"
    CA_CERT_FILE = "ca.pem"
    SERVER_KEY_FILE = "server-key.pem"
    SERVER_CERT_FILE = "server.pem"
    CA_TRUST_MARKER = "ca.trusted"
    HOST_CERTS_DIR = "host-certs"
    SERVER_SANS = %w[DNS:localhost DNS:*.localhost DNS:*.local].freeze

    CERT_FILENAME_SUFFIX_LEN = "-key.pem".length
    # Per-component filename limit (NAME_MAX 255) minus the longest suffix.
    MAX_FILENAME_BASE = 255 - CERT_FILENAME_SUFFIX_LEN
    # X.509 CN length limit (RFC 5280 §4.1.2.6); SANs carry the real name.
    MAX_CN_LENGTH = 64

    class << self
      # certs.ts fileExists: present and readable by this process.
      def file_exists?(path) = File.readable?(path)

      # Ensure a CA and the default server cert exist in `state_dir`. The CA is
      # regenerated when missing, expiring, SHA-1 signed or carrying duplicate
      # extensions; the server cert additionally when it lacks the *.local SAN.
      def ensure_certs(state_dir = State.dir)
        ca_cert_path = File.join(state_dir, CA_CERT_FILE)
        ca_key_path = File.join(state_dir, CA_KEY_FILE)
        server_cert_path = File.join(state_dir, SERVER_CERT_FILE)
        server_key_path = File.join(state_dir, SERVER_KEY_FILE)

        ca_generated = false
        if !file_exists?(ca_cert_path) || !file_exists?(ca_key_path) || !cert_valid?(ca_cert_path) ||
           !cert_signature_strong?(ca_cert_path) || duplicate_extensions?(ca_cert_path)
          generate_ca(state_dir)
          ca_generated = true
        end

        if ca_generated || !file_exists?(server_cert_path) || !file_exists?(server_key_path) ||
           !cert_valid?(server_cert_path) || !cert_signature_strong?(server_cert_path) ||
           !cert_sans_complete?(server_cert_path)
          generate_server_cert(state_dir)
        end

        { cert_path: server_cert_path, key_path: server_key_path, ca_path: ca_cert_path, ca_generated: ca_generated }
      end

      # Replace dots with underscores and drop everything but [a-z0-9_-]. Names
      # that would overflow NAME_MAX keep a readable prefix plus a hash of the
      # full hostname, so the mapping stays deterministic and collision-free.
      def sanitize_host_for_filename(hostname)
        safe = hostname.tr(".", "_").gsub(/[^a-z0-9_-]/i, "")
        return safe if safe.length <= MAX_FILENAME_BASE

        hash = Digest::SHA256.hexdigest(hostname)[0, 16]
        "#{safe[0, MAX_FILENAME_BASE - hash.length - 1]}_#{hash}"
      end

      # A callable `(servername) -> OpenSSL::SSL::SSLContext` for the TLS server.
      # Bare `localhost` uses the default cert; any other name must sit under a
      # configured TLD (else it raises, aborting the handshake — no cert is ever
      # minted for an arbitrary SNI name). Concurrent handshakes for the same
      # host share one generation.
      def create_sni_callback(state_dir, default_cert, default_key, tlds = Constants::DEFAULT_TLD, ca_cert = nil)
        SNI.new(state_dir, default_cert, default_key, Array(tlds), ca_cert)
      end

      def cert_valid?(path)
        cert = OpenSSL::X509::Certificate.new(File.read(path))
        Time.now + EXPIRY_BUFFER < cert.not_after
      rescue StandardError
        false
      end

      # The server cert must cover *.local (added in later versions).
      def cert_sans_complete?(path)
        san_text(path).match?(/DNS:\*\.local\b/)
      rescue StandardError
        false
      end

      # A wildcard directly under a bare TLD ("*.localhost"); Apple platforms reject these.
      def tld_wildcard_san?(path)
        san_text(path).match?(/DNS:\*\.[^.,\s]+(,|\z)/)
      rescue StandardError
        true
      end

      # Reject SHA-1 signatures ("ca md too weak").
      def cert_signature_strong?(path)
        cert = OpenSSL::X509::Certificate.new(File.read(path))
        !cert.signature_algorithm.downcase.include?("sha1")
      rescue StandardError
        false
      end

      # RFC 5280 requires unique extensions; macOS rejects every chain through a
      # CA that repeats one, so such a CA is regenerated.
      def duplicate_extensions?(path)
        oids = OpenSSL::X509::Certificate.new(File.read(path)).extensions.map(&:oid)
        oids.uniq.size != oids.size
      rescue StandardError
        false
      end

      def generate_ca(state_dir)
        key_path = File.join(state_dir, CA_KEY_FILE)
        cert_path = File.join(state_dir, CA_CERT_FILE)

        key = OpenSSL::PKey::EC.generate(CURVE)
        name = OpenSSL::X509::Name.parse(CA_SUBJECT)
        cert = new_cert(name, name, key, CA_VALIDITY_DAYS)
        ef = extension_factory(cert, cert)
        cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(ef.create_extension("keyUsage", "keyCertSign,cRLSign", true))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash"))
        cert.add_extension(ef.create_extension("authorityKeyIdentifier", "keyid:always"))
        cert.sign(key, OpenSSL::Digest.new("SHA256"))

        write_file(key_path, key.to_pem, 0o600)
        write_file(cert_path, cert.to_pem, 0o644)
        State.fix_ownership(key_path)
        State.fix_ownership(cert_path)

        FileUtils.rm_f(File.join(state_dir, CA_TRUST_MARKER))
        # Host certs issued by the previous CA no longer chain to this one.
        FileUtils.rm_rf(File.join(state_dir, HOST_CERTS_DIR))
        { cert_path: cert_path, key_path: key_path }
      end

      def generate_server_cert(state_dir)
        ca_cert, ca_key = load_ca(state_dir)
        key_path = File.join(state_dir, SERVER_KEY_FILE)
        cert_path = File.join(state_dir, SERVER_CERT_FILE)
        cert, key = sign_leaf(ca_cert, ca_key, "localhost", SERVER_SANS)
        write_file(key_path, key.to_pem, 0o600)
        write_file(cert_path, cert.to_pem, 0o644)
        State.fix_ownership(key_path)
        State.fix_ownership(cert_path)
        { cert_path: cert_path, key_path: key_path }
      end

      # Mint (and persist under host-certs/) a leaf for one hostname.
      def generate_host_cert(state_dir, hostname)
        ca_cert, ca_key = load_ca(state_dir)
        host_dir = File.join(state_dir, HOST_CERTS_DIR)
        unless File.directory?(host_dir)
          FileUtils.mkdir_p(host_dir, mode: 0o755)
          State.fix_ownership(host_dir)
        end
        safe = sanitize_host_for_filename(hostname)
        key_path = File.join(host_dir, "#{safe}-key.pem")
        cert_path = File.join(host_dir, "#{safe}.pem")

        sans = [ "DNS:#{hostname}" ]
        parts = hostname.split(".")
        sans << "DNS:*.#{parts[1..].join('.')}" if parts.length >= 3
        cn = hostname.length > MAX_CN_LENGTH ? hostname[0, MAX_CN_LENGTH] : hostname
        cert, key = sign_leaf(ca_cert, ca_key, cn, sans)

        write_file(key_path, key.to_pem, 0o600)
        write_file(cert_path, cert.to_pem, 0o644)
        State.fix_ownership(key_path)
        State.fix_ownership(cert_path)
        { cert_path: cert_path, key_path: key_path }
      end

      def load_ca(state_dir)
        [ OpenSSL::X509::Certificate.new(File.read(File.join(state_dir, CA_CERT_FILE))),
          OpenSSL::PKey.read(File.read(File.join(state_dir, CA_KEY_FILE))) ]
      end

      private

      def sign_leaf(ca_cert, ca_key, common_name, sans)
        key = OpenSSL::PKey::EC.generate(CURVE)
        cert = new_cert(OpenSSL::X509::Name.new([ [ "CN", common_name ] ]), ca_cert.subject, key, SERVER_VALIDITY_DAYS)
        ef = extension_factory(cert, ca_cert)
        cert.add_extension(ef.create_extension("authorityKeyIdentifier", "keyid,issuer"))
        cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE"))
        cert.add_extension(ef.create_extension("keyUsage", "digitalSignature,keyEncipherment"))
        cert.add_extension(ef.create_extension("extendedKeyUsage", "serverAuth"))
        cert.add_extension(ef.create_extension("subjectAltName", sans.join(",")))
        cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))
        [ cert, key ]
      end

      def new_cert(subject, issuer, key, days)
        now = Time.now
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = OpenSSL::BN.rand(63)
        cert.subject = subject
        cert.issuer = issuer
        cert.public_key = OpenSSL::PKey.read(key.public_to_pem)
        cert.not_before = now - NOT_BEFORE_SKEW
        cert.not_after = now + days * 86_400
        cert
      end

      def extension_factory(subject, issuer)
        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = subject
        ef.issuer_certificate = issuer
        ef
      end

      def san_text(path)
        cert = OpenSSL::X509::Certificate.new(File.read(path))
        cert.extensions.find { |e| e.oid == "subjectAltName" }&.value.to_s
      end

      # Create with a private mode from the first byte (no umask window).
      def write_file(path, content, mode)
        tmp = "#{path}.#{Process.pid}.tmp"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, mode) { |f| f.write(content) }
        File.chmod(mode, tmp)
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end
    end

    # The SNI selector (createSNICallback). Memory cache → valid on-disk cert →
    # one deduplicated generation per hostname.
    class SNI
      def initialize(state_dir, default_cert, default_key, tlds, ca_cert)
        @state_dir = state_dir
        @tlds = tlds
        @ca_cert = ca_cert && to_cert(ca_cert)
        @cache = {}
        @pending = {}
        @lock = Mutex.new
        @default_context = build_context(to_cert(default_cert), to_key(default_key))
      end

      def call(servername)
        return @default_context if servername == "localhost"

        name = servername.to_s.downcase
        if !name.match?(/\A[a-z0-9.-]+\z/) || @tlds.none? { |tld| name.end_with?(".#{tld}") }
          raise Error, "Refusing certificate for #{servername}: not under a configured TLD"
        end

        cached = @cache[servername]
        return cached if cached

        from_disk = load_from_disk(servername)
        return @cache[servername] = from_disk if from_disk

        generate(servername)
      end

      private

      def load_from_disk(servername)
        safe = Certs.sanitize_host_for_filename(servername)
        host_dir = File.join(@state_dir, HOST_CERTS_DIR)
        cert_path = File.join(host_dir, "#{safe}.pem")
        key_path = File.join(host_dir, "#{safe}-key.pem")
        return nil unless Certs.file_exists?(cert_path) && Certs.file_exists?(key_path) &&
                          Certs.cert_valid?(cert_path) && Certs.cert_signature_strong?(cert_path) &&
                          !Certs.tld_wildcard_san?(cert_path)

        build_context(OpenSSL::X509::Certificate.new(File.read(cert_path)), OpenSSL::PKey.read(File.read(key_path)))
      rescue StandardError
        nil # e.g. a root-owned cached cert; regenerate
      end

      # One generation per hostname even when handshakes race: later callers
      # wait on the first one's result.
      def generate(servername)
        waiter = nil
        owner = false
        @lock.synchronize do
          return @cache[servername] if @cache[servername]

          waiter = @pending[servername]
          unless waiter
            waiter = @pending[servername] = Thread::Queue.new
            owner = true
          end
        end
        return wait_for(waiter, servername) unless owner

        begin
          paths = Certs.generate_host_cert(@state_dir, servername)
          context = build_context(OpenSSL::X509::Certificate.new(File.read(paths[:cert_path])),
                                  OpenSSL::PKey.read(File.read(paths[:key_path])))
          @lock.synchronize do
            @cache[servername] = context
            @pending.delete(servername)
          end
          waiter.close
          context
        rescue StandardError => e
          @lock.synchronize { @pending.delete(servername) }
          waiter.push(e)
          waiter.close
          raise
        end
      end

      def wait_for(waiter, servername)
        result = waiter.pop
        raise result if result.is_a?(Exception)

        @cache[servername] || raise(Error, "Certificate generation for #{servername} failed")
      end

      def build_context(cert, key)
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.add_certificate(cert, key, @ca_cert ? [ @ca_cert ] : [])
        ctx.alpn_protocols = %w[h2 http/1.1]
        ctx.alpn_select_cb = ->(offered) { (%w[h2 http/1.1] & offered).first || "http/1.1" }
        ctx.session_id_context = "portless"
        ctx
      end

      def to_cert(value) = value.is_a?(OpenSSL::X509::Certificate) ? value : OpenSSL::X509::Certificate.new(value)
      def to_key(value) = value.is_a?(OpenSSL::PKey::PKey) ? value : OpenSSL::PKey.read(value)
    end

    # ---------------------------------------------------------------------
    # Instance API: CA generation on demand.

    def initialize(state_dir = nil)
      @state_dir = state_dir
    end

    def state_dir = @state_dir || State.dir

    def ensure_ca!
      ca_cert_path = File.join(state_dir, CA_CERT_FILE)
      ca_key_path = File.join(state_dir, CA_KEY_FILE)
      return if self.class.file_exists?(ca_cert_path) && self.class.file_exists?(ca_key_path) &&
                self.class.cert_valid?(ca_cert_path) &&
                self.class.cert_signature_strong?(ca_cert_path) && !self.class.duplicate_extensions?(ca_cert_path)

      self.class.generate_ca(state_dir)
    end

    def ensure_certs = self.class.ensure_certs(state_dir)
  end
end
