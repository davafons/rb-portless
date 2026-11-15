# frozen_string_literal: true

require "fileutils"

module Portless
  # `clean` helpers: only allowlisted files inside each state directory are
  # removed, CA identity is kept when untrusting fails, proxy runtime markers
  # are kept when the proxy stop is unconfirmed. Mirrors portless's
  # clean-utils.ts and the cleanup-step runner in cli.ts. (Upstream's legacy
  # /tmp/portless system dir has no rb-portless equivalent.)
  module CleanUtils
    module_function

    PORTLESS_STATE_FILES = %w[
      routes.json routes.json.tmp routes.lock proxy.pid proxy.port proxy.start proxy.start.tmp proxy.log
      proxy.tls proxy.custom-cert proxy.tld proxy.tlds proxy.lan proxy.hosts-sync-token
      proxy.hosts-sync-token.tmp ca.trusted ca.trust-refresh-pending ca-key.pem ca.pem server-key.pem
      server.pem server.csr server-ext.cnf ca.srl cloudflared.yml
    ].freeze
    HOST_CERTS_DIR = "host-certs"
    CA_IDENTITY_FILES = %w[ca-key.pem ca.pem ca.trust-refresh-pending].freeze
    PROXY_RUNTIME_FILES = %w[
      proxy.pid proxy.port proxy.start proxy.start.tmp proxy.log proxy.hosts-sync-token
      proxy.hosts-sync-token.tmp proxy.tls proxy.custom-cert proxy.tld proxy.tlds proxy.lan
    ].freeze
    CLEANUP_STEP_ORDER = %w[ca files hosts].freeze

    def collect_state_dirs_for_cleanup_with_failures
      dirs = []
      failures = []
      [ File.expand_path(Constants::DEFAULT_STATE_DIR), ENV["PORTLESS_STATE_DIR"] ].each do |d|
        trimmed = d.to_s.strip
        next if trimmed.empty?

        resolved = File.expand_path(trimmed)
        canonical = begin
          File.realpath(resolved)
        rescue Errno::ENOENT
          next
        rescue StandardError
          failures << resolved unless failures.include?(resolved)
          next
        end
        if State.explain_unsafe(resolved)
          failures << resolved unless failures.include?(resolved)
          next
        end
        dirs << canonical unless dirs.include?(canonical)
      end
      { dirs: dirs, failures: failures }
    end

    def attempt_ca_trust_removal_for_cleanup(state_dirs)
      state_dirs.each_with_object({}) do |dir, results|
        next unless State.cleanable?(dir)

        ca = File.join(dir, "ca.pem")
        begin
          if File.symlink?(ca)
            results[dir] = { removed: false, error: "Could not inspect CA certificate: refusing symlinked ca.pem" }
            next
          end
          File.stat(ca)
        rescue Errno::ENOENT
          next
        rescue StandardError => e
          results[dir] = { removed: false, error: "Could not inspect CA certificate: #{e.message}" }
          next
        end
        results[dir] = yield(dir)
      end
    end

    # => paths that could not be removed.
    def remove_portless_state_files(dir, preserve_ca_identity: false, preserve_proxy_runtime: false)
      begin
        File.lstat(dir)
      rescue Errno::ENOENT
        return []
      rescue StandardError
        return [ dir ]
      end
      return [ dir ] unless State.cleanable?(dir)

      failures = []
      PORTLESS_STATE_FILES.each do |f|
        next if preserve_ca_identity && CA_IDENTITY_FILES.include?(f)
        next if preserve_proxy_runtime && PROXY_RUNTIME_FILES.include?(f)

        file = File.join(dir, f)
        begin
          f == "routes.lock" ? FileUtils.rm_rf(file) : File.unlink(file)
        rescue Errno::ENOENT
          nil
        rescue StandardError
          failures << file
        end
      end
      return failures if preserve_proxy_runtime

      host_certs = File.join(dir, HOST_CERTS_DIR)
      begin
        stat = File.lstat(host_certs)
        stat.symlink? || !stat.directory? ? File.unlink(host_certs) : FileUtils.rm_rf(host_certs)
      rescue Errno::ENOENT
        nil
      rescue StandardError
        failures << host_certs
      end
      failures
    end

    def run_cleanup_steps(steps, state_dirs, preserve_proxy_runtime)
      ca_results = {}
      failed = []
      if steps.include?("ca")
        ca_results = attempt_ca_trust_removal_for_cleanup(state_dirs) do |dir|
          Trust.untrust_ca(dir)
        rescue StandardError => e
          { removed: false, error: e.message }
        end
        failed = ca_results.reject { |_, r| r[:removed] }.keys
      end
      state_failures = []
      if steps.include?("files")
        state_dirs.each do |dir|
          state_failures.concat(remove_portless_state_files(dir, preserve_ca_identity: failed.include?(dir),
                                                                 preserve_proxy_runtime: preserve_proxy_runtime))
        end
      end
      hosts_cleaned = true
      if steps.include?("hosts")
        hosts_cleaned = begin
          Hosts.clean
          true
        rescue StandardError
          false
        end
      end
      { ca_results: ca_results, failed_ca_state_dirs: failed, state_failures: state_failures,
        hosts_cleaned: hosts_cleaned }
    end
  end
end
