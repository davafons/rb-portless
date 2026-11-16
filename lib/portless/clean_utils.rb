# frozen_string_literal: true

require "fileutils"
require "json"

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
    CLEAN_ELEVATED_STEPS_ENV = "PORTLESS_INTERNAL_CLEAN_STEPS"
    CLEAN_ELEVATED_DIRS_ENV = "PORTLESS_INTERNAL_CLEAN_DIRS"
    CLEAN_ELEVATED_PRESERVE_PROXY_ENV = "PORTLESS_INTERNAL_CLEAN_PRESERVE_PROXY"

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
        if State.explain_unsafe_state_dir(resolved)
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

    # Whether CA identity must survive because removal or trust refresh is
    # unfinished. cli.ts shouldPreserveCAIdentity.
    def preserve_ca_identity?(dir, failed_ca_state_dirs)
      failed_ca_state_dirs.include?(dir) || Trust.trust_refresh_pending?(dir) || Trust.trusted?(dir)
    end

    # Remove allowlisted state files; => every path that remains.
    # cli.ts removeStateFilesForCleanup.
    def remove_state_files_for_cleanup(state_dirs, failed_ca_state_dirs, preserve_proxy_runtime)
      state_dirs.flat_map do |dir|
        remove_portless_state_files(
          dir, preserve_ca_identity: preserve_proxy_runtime || preserve_ca_identity?(dir, failed_ca_state_dirs),
               preserve_proxy_runtime: preserve_proxy_runtime
        )
      end.uniq
    end

    # cli.ts runCleanupSteps.
    def run_cleanup_steps(steps, state_dirs, preserve_proxy_runtime)
      ca_results = {}
      if steps.include?("ca")
        ca_results = attempt_ca_trust_removal_for_cleanup(state_dirs) do |dir|
          Trust.untrust_ca(dir)
        rescue StandardError => e
          { removed: false, error: e.message }
        end
      end
      failed = ca_results.reject { |_, r| r[:removed] }.keys
      state_failures = steps.include?("files") ? remove_state_files_for_cleanup(state_dirs, failed, preserve_proxy_runtime) : []
      hosts_cleaned = !steps.include?("hosts") || Hosts.clean_hosts_file
      { ca_results: ca_results, failed_ca_state_dirs: failed, state_failures: state_failures,
        hosts_cleaned: hosts_cleaned }
    end

    # The internal allowlist of steps a sudo retry runs, or nil.
    # cli.ts parseCleanupSteps.
    def parse_cleanup_steps(value)
      trimmed = value.to_s.strip
      return nil if trimmed.empty?

      requested = trimmed.split(",").map(&:strip).uniq
      unknown = requested.find { |step| !CLEANUP_STEP_ORDER.include?(step) }
      raise Error, "Unknown cleanup step: #{unknown}" if unknown

      CLEANUP_STEP_ORDER.select { |step| requested.include?(step) }
    end

    # The exact state dirs the parent clean approved. cli.ts parseCleanupDirs.
    def parse_cleanup_dirs(value)
      return [] if value.nil? || value.empty?

      parsed = JSON.parse(value)
      unless parsed.is_a?(Array) && parsed.all? { |entry| entry.is_a?(String) && entry.start_with?("/") }
        raise Error, "Invalid cleanup directories"
      end

      parsed.uniq
    end

    def cleanup_step_label(step)
      return "CA trust removal" if step == "ca"
      return "state files" if step == "files"

      "hosts file"
    end

    # Whether the unprivileged process can inspect a state dir. cli.ts canInspectStateDir.
    def can_inspect_state_dir?(dir) = File.readable?(dir) && File.executable?(dir)

    # Retry only the failed privileged steps under sudo, against the exact
    # approved state dirs. => exit status, or nil when sudo could not run.
    # cli.ts runElevatedCleanup.
    def run_elevated_cleanup(steps, state_dirs, preserve_proxy_runtime)
      return 0 if steps.empty?

      labels = steps.map { |step| cleanup_step_label(step) }.join(", ")
      puts Colors.yellow("Cleanup needs elevated privileges. Requesting sudo for #{labels}...")
      home = ENV["HOME"].to_s
      result = Privilege.run_sudo([
        "env", *(home.empty? ? [] : [ "HOME=#{home}" ]),
        "#{CLEAN_ELEVATED_STEPS_ENV}=#{steps.join(',')}",
        "#{CLEAN_ELEVATED_DIRS_ENV}=#{JSON.generate(state_dirs)}",
        *(preserve_proxy_runtime ? [ "#{CLEAN_ELEVATED_PRESERVE_PROXY_ENV}=1" ] : []),
        *Privilege.cli_argv, "clean", "--yes"
      ])
      if result.error
        warn Colors.red("Could not run sudo: #{result.error}", io: $stderr)
        return nil
      end
      result.status.exitstatus
    end

    # The elevated re-entry: run the approved steps, exit 0 only when all of
    # them finished. cli.ts handleClean (requestedCleanupSteps branch).
    def run_requested_cleanup(steps)
      approved = parse_cleanup_dirs(ENV[CLEAN_ELEVATED_DIRS_ENV])
      preserve_proxy_runtime = ENV[CLEAN_ELEVATED_PRESERVE_PROXY_ENV] == "1"
      cleanable = approved.select { |dir| State.cleanable?(dir) }
      left = run_cleanup_steps(steps, cleanable, preserve_proxy_runtime)
      clean = cleanable.length == approved.length && left[:failed_ca_state_dirs].empty? &&
              left[:state_failures].empty? && left[:hosts_cleaned]
      clean ? 0 : 1
    end
  end
end
