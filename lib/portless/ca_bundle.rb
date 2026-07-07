# frozen_string_literal: true

require "openssl"
require "fileutils"

module Portless
  # The CA bundle handed to proxied apps via SSL_CERT_FILE.
  #
  # SSL_CERT_FILE *replaces* OpenSSL's trust file rather than adding to it, so
  # pointing an app at our local CA alone makes it distrust every public
  # certificate — Frankfurter, Stripe, S3, GitHub — and all outbound HTTPS from
  # the dev server fails with "unable to get local issuer certificate". We
  # instead assemble a combined bundle (the system's default roots + our CA) and
  # point apps at that, so they trust the public web *and* sibling .localhost
  # hosts served under our CA.
  module CaBundle
    # Well-known system trust stores, tried when OpenSSL's compiled-in default
    # isn't readable (varies by distro / OpenSSL build).
    FALLBACK_ROOTS = [
      "/etc/ssl/cert.pem",                     # macOS, OpenBSD
      "/etc/ssl/certs/ca-certificates.crt",    # Debian, Ubuntu, Alpine
      "/etc/pki/tls/certs/ca-bundle.crt",      # Fedora, RHEL
      "/etc/ssl/ca-bundle.pem"                 # openSUSE
    ].freeze

    module_function

    # Absolute path to the combined bundle, (re)building it when missing or older
    # than either input. Returns nil when our CA doesn't exist yet or assembly
    # fails, so the caller simply omits the SSL_CERT_FILE override (apps keep
    # their own defaults) rather than shipping a broken trust store.
    def path
      return nil unless File.exist?(State.ca_cert)

      bundle = bundle_path
      rebuild(bundle) if stale?(bundle)
      File.exist?(bundle) ? bundle : nil
    rescue StandardError
      nil
    end

    def bundle_path = State.path("ca-bundle.pem")

    def stale?(bundle)
      return true unless File.exist?(bundle)

      inputs = [ State.ca_cert, system_roots ].compact.select { |f| File.exist?(f) }
      inputs.empty? || inputs.any? { |f| File.mtime(f) > File.mtime(bundle) }
    end

    def rebuild(bundle)
      State.ensure_dir!
      pems = []
      roots = system_roots
      pems << File.read(roots) if roots && File.exist?(roots)
      pems << File.read(State.ca_cert)

      # Atomic write: concurrent app starts may both rebuild; a temp file + rename
      # keeps any reader from seeing a half-written bundle.
      tmp = "#{bundle}.#{Process.pid}.tmp"
      File.write(tmp, "#{pems.join("\n").strip}\n")
      File.rename(tmp, bundle)
      State.fix_ownership(bundle)
    end

    # The public root store OpenSSL would use by default, so our bundle is a
    # superset of it. An operator-set SSL_CERT_FILE wins (but never our own
    # bundle, which would read itself in circles).
    def system_roots
      env = ENV["SSL_CERT_FILE"].to_s
      return env if !env.empty? && env != bundle_path && File.exist?(env)

      default = OpenSSL::X509::DEFAULT_CERT_FILE
      return default if default && File.exist?(default)

      FALLBACK_ROOTS.find { |f| File.exist?(f) }
    end
  end
end
