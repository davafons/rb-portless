# frozen_string_literal: true

require "json"
require "fileutils"
require "ipaddr"

module Portless
  # Reopened (same superclass) in rb-portless.rb; declared here because the
  # error classes below subclass it at load time.
  class Error < StandardError; end

  # A routes file that exists but cannot be read or parsed, so it is not an
  # empty table. `reason` is :corrupt or :unreadable.
  class RoutesFileError < Error
    attr_reader :file, :reason

    def initialize(file, reason, message)
      super(message)
      @file = file
      @reason = reason
    end
  end

  # Thrown when a route is already registered by a live process and --force was
  # not specified. With --force, the existing process is killed instead.
  class RouteConflictError < Error
    attr_reader :hostname, :existing_pid

    def initialize(hostname, existing_pid)
      super(
        if existing_pid.zero?
          "\"#{hostname}\" is a static alias. Use --force to replace it; re-add the alias with \"rb-portless alias\" afterwards."
        else
          "\"#{hostname}\" is already registered by a running process (PID #{existing_pid}). Use --force to override."
        end
      )
      @hostname = hostname
      @existing_pid = existing_pid
    end
  end

  # The on-disk routing table (routes.json): hostname → backend port → owning
  # pid. No daemon API: apps register by editing this file under a directory
  # mutex, and the proxy reads it. Mirrors portless's routes.ts
  # function-for-function (camelCase → snake_case).
  class RouteStore
    # How long before a lock directory is considered stale and forcibly removed.
    STALE_LOCK_THRESHOLD = 10.0
    # Total time budget for acquiring the file lock before giving up.
    LOCK_TIMEOUT = 15.0
    # Initial / maximum delay between lock retries (doubles each attempt).
    LOCK_RETRY_BASE = 0.010
    LOCK_RETRY_CAP = 0.100
    FILE_MODE = 0o644

    # camelCase on-disk key ↔ snake_case reader, in upstream's field order.
    FIELDS = {
      hostname: "hostname", port: "port", pid: "pid", registered_at: "registeredAt",
      upstream: "upstream", retired: "retired", child_pgid: "childPgid",
      child_start_time: "childStartTime", orphan_pid: "orphanPid",
      orphan_start_time: "orphanStartTime", tailscale_url: "tailscaleUrl",
      tailscale_https_port: "tailscaleHttpsPort", tailscale_funnel: "tailscaleFunnel",
      ngrok_url: "ngrokUrl", ngrok_pid: "ngrokPid", cloudflare_url: "cloudflareUrl",
      cloudflare_pid: "cloudflarePid"
    }.freeze

    # Metadata update_route may patch (RouteMetadataPatch).
    METADATA_FIELDS = %i[child_pgid child_start_time tailscale_url tailscale_https_port
                         tailscale_funnel ngrok_url ngrok_pid cloudflare_url cloudflare_pid].freeze

    # One RouteMapping. `upstream` is `{ tls: bool?, host: String? }` (symbol
    # keys). Unknown on-disk keys ride along in `extra` so a write never drops
    # what a newer version recorded.
    #
    # Serialized like a JS object: keys read from disk keep their order, keys
    # set since then follow in the order routes.ts assigns them (FIELDS order),
    # and `retired` (added by `{ ...route, retired: true }`) comes last.
    Route = Struct.new(*FIELDS.keys, :extra, keyword_init: true) do
      attr_accessor :key_order

      def self.from_h(hash)
        attrs = FIELDS.to_h { |reader, key| [ reader, hash[key] ] }
        if attrs[:upstream].is_a?(Hash)
          attrs[:upstream] = attrs[:upstream].to_h { |k, v| [ k.to_sym, v ] }
        end
        new(**attrs, extra: hash.reject { |key, _| FIELDS.value?(key) }).tap { |route| route.key_order = hash.keys }
      end

      def alias? = pid.to_i.zero?

      def to_h
        order = key_order || []
        extras = extra || {}
        out = {}
        order.each do |key|
          if (reader = FIELDS.key(key))
            out[key] = json_value(reader) unless self[reader].nil?
          elsif extras.key?(key)
            out[key] = extras[key]
          end
        end
        (FIELDS.keys - [ :retired ] + [ :retired ]).each do |reader|
          key = FIELDS[reader]
          out[key] = json_value(reader) unless order.include?(key) || self[reader].nil?
        end
        extras.each { |key, value| out[key] = value unless order.include?(key) }
        out
      end

      def json_value(reader)
        value = self[reader]
        reader == :upstream ? value.to_h { |k, v| [ k.to_s, v ] } : value
      end

      def to_json(*args) = to_h.to_json(*args)
    end

    # Whether `value` is a valid route `upstream` ({tls?: bool, host?: authority}).
    def self.valid_upstream?(value)
      return false unless value.is_a?(Hash)

      upstream = value.transform_keys(&:to_s)
      return false if upstream.keys.any? { |key| key != "tls" && key != "host" }
      return false if upstream.key?("tls") && upstream["tls"] != true && upstream["tls"] != false
      return true unless upstream.key?("host")

      authority = upstream["host"]
      return false unless authority.is_a?(String) && !authority.empty?

      match = /\A(\[[^\]]+\]|[^:]+)(?::([0-9]+))?\z/.match(authority)
      return false unless match

      hostname = match[1]
      if match[2] && (match[2].length > 5 || match[2].to_i < 1 || match[2].to_i > 65_535)
        return false
      end
      return ipv6?(hostname[1..-2]) if hostname.start_with?("[")
      return ipv4?(hostname) if hostname.match?(/\A[0-9.]+\z/) && hostname.include?(".")
      return false if hostname.length > 253

      hostname.split(".", -1).all? { |label| label.match?(/\A(?!-)[a-z0-9-]{1,63}(?<!-)\z/i) }
    end

    class << self
      # net.isIPv4: four dotted decimal octets, 0-255, no leading zeros.
      def ipv4?(value)
        value.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/) &&
          value.split(".").all? { |octet| octet.to_i <= 255 && octet == octet.to_i.to_s }
      end

      def ipv6?(value)
        !value.include?("%") && IPAddr.new(value).ipv6?
      rescue IPAddr::Error
        false
      end
    end

    # Runtime check that a parsed JSON value is a valid RouteMapping.
    def self.valid_route?(value)
      value.is_a?(Hash) &&
        value["hostname"].is_a?(String) &&
        value["port"].is_a?(Numeric) &&
        value["pid"].is_a?(Numeric) &&
        (!value.key?("upstream") || valid_upstream?(value["upstream"]))
    end

    # Whether a process exists, treating permission denial as alive.
    def self.process_alive?(pid)
      pid = pid.to_i
      return false if pid <= 0

      Process.kill(0, pid)
      true
    rescue Errno::EPERM
      true
    rescue StandardError
      false
    end

    attr_reader :dir

    def initialize(dir = nil, on_warning: nil)
      @dir = dir || State.dir
      @routes_path = File.join(@dir, "routes.json")
      @lock_path = File.join(@dir, "routes.lock")
      @on_warning = on_warning
    end

    def routes_path = @routes_path
    def pid_path = File.join(@dir, "proxy.pid")
    def port_file_path = File.join(@dir, "proxy.port")
    def start_time_path = File.join(@dir, "proxy.start")

    def ensure_dir = State.require_state_dir(@dir)

    # Why what this directory records must not be acted on, or nil when only its
    # owner can change it. A directory that does not exist yet records nothing.
    def untrusted_reason = File.exist?(@dir) ? State.explain_unsafe_state_dir(@dir) : nil

    # Routes for the proxy to serve. Raises when untrusted_reason rejects the dir.
    def load_trusted_routes
      unsafe = untrusted_reason
      raise Error, "Cannot use state directory #{@dir}: #{unsafe}" if unsafe

      load_routes
    end

    # Whether the process that owns `route` is still running.
    def route_owner_alive?(route) = !stale?(route)

    # The routes a caller should act on: entries whose portless process is
    # still alive, plus aliases. Stale entries stay in the file for `prune`.
    def load_routes = read_route_file.reject { |route| stale?(route) }

    # All valid routes without filtering dead pids, active entries first.
    def load_routes_raw = read_route_file

    # Return routes whose owners are dead without removing them from storage.
    def find_stale_routes
      with_lock { read_route_file.select { |route| stale?(route) } }
    end

    # Register a route. With `force`, a live different owner is sent SIGTERM
    # first. Returns the killed pid (if any). A stale record for the same
    # hostname is left for `prune`.
    def add_route(hostname:, port:, pid:, force: false, upstream: nil)
      upstream = upstream&.to_h { |k, v| [ k.to_sym, v ] }
      raise Error, "Invalid upstream configuration" if upstream && !self.class.valid_upstream?(upstream)

      killed_pid = nil
      mutate_routes(force ? hostname : nil) do |routes|
        if !force && skipped_route?(hostname)
          raise Error, "\"#{hostname}\" has an invalid or unsupported stored route. Use --force to replace it."
        end

        existing = find_active_route(routes, hostname)
        if existing && existing.pid != pid
          raise RouteConflictError.new(hostname, existing.pid.to_i) unless force

          # --force: kill the existing process before taking over; an alias has none.
          unless existing.alias?
            begin
              Process.kill("TERM", existing.pid.to_i)
              killed_pid = existing.pid
            rescue StandardError
              nil # exited between the check and the kill
            end
          end
        end
        routes.reject! { |route| route.hostname == hostname && !stale?(route) }
        routes << Route.new(hostname: hostname, port: port, pid: pid,
                            registered_at: (Time.now.to_f * 1000).to_i, upstream: upstream, extra: {})
        [ nil, true ]
      end
      killed_pid
    end

    # Move a corrupt routes file aside so a write path can start with an empty
    # table. Missing and valid files are left alone; an unreadable file raises.
    def recover_corrupt_routes_file
      with_lock do
        read_route_file
        false
      rescue RoutesFileError => e
        raise unless e.reason == :corrupt

        backup = "#{@routes_path}.corrupt-#{(Time.now.to_f * 1000).to_i}"
        File.rename(@routes_path, backup)
        @on_warning&.call("Moved corrupted routes file to #{backup}. Starting with no routes.")
        true
      end
    end

    # Record the group member `prune` verified, only while the stored stale
    # record is still the one it examined.
    def record_stale_orphan(route, orphan_pid, orphan_start_time)
      mutate_routes do |routes|
        current = routes.find { |entry| same_route_record?(entry, route) }
        next [ false, false ] unless current && stale?(current)

        current.orphan_pid = orphan_pid
        current.orphan_start_time = orphan_start_time
        [ true, true ]
      end
    end

    # Remove one route only while its recorded owner is still dead.
    def remove_stale_route(hostname, owner_pid)
      mutate_routes do |routes|
        index = routes.index { |r| r.hostname == hostname && r.pid == owner_pid && stale?(r) }
        next [ false, false ] unless index

        routes.delete_at(index)
        [ true, true ]
      end
    end

    # Merge metadata into the live entry for `hostname`. A nil value deletes the
    # field; absent keys are left alone. Keys are snake_case (child_pgid, …) or
    # upstream's camelCase.
    def update_route(hostname, fields)
      fields = normalize_patch(fields)
      mutate_routes do |routes|
        route = find_active_route(routes, hostname)
        next [ nil, false ] unless route

        fields.each { |key, value| route[key] = value }
        [ nil, true ]
      end
    end

    # Hand a route over to another process, only while `from_pid` still owns it.
    def transfer_route(hostname, from_pid, to_pid)
      mutate_routes do |routes|
        route = routes.find { |r| r.hostname == hostname && r.pid == from_pid && !stale?(r) }
        next [ false, false ] unless route

        route.pid = to_pid
        # Tunnels and Serve config stop with the previous owner.
        %i[ngrok_url ngrok_pid cloudflare_url cloudflare_pid
           tailscale_url tailscale_https_port tailscale_funnel].each { |key| route[key] = nil }
        [ true, true ]
      end
    end

    # Remove a route by hostname; with `owner_pid`, only while that pid still
    # owns it (so a force-replaced predecessor can't delete its successor's
    # route). Stale records are left for `prune`. Returns whether it removed one.
    def remove_route(hostname, owner_pid: nil)
      mutate_routes do |routes|
        before = routes.size
        routes.reject! do |route|
          route.hostname == hostname && !stale?(route) && (owner_pid.nil? || route.pid == owner_pid)
        end
        changed = routes.size != before
        [ changed, changed ]
      end
    end

    private

    def stale?(route)
      route.retired == true || (route.pid != 0 && !self.class.process_alive?(route.pid))
    end

    def recovery_data?(route)
      %i[child_pgid child_start_time orphan_pid orphan_start_time tailscale_https_port
         ngrok_pid cloudflare_pid].any? { |key| !route[key].nil? }
    end

    def same_route_record?(a, b)
      a.hostname == b.hostname && a.port == b.port && a.pid == b.pid &&
        a.child_pgid == b.child_pgid && a.child_start_time == b.child_start_time
    end

    # Every live route plus stale records that still hold recovery data, retired.
    def retain_stale_records(routes)
      routes.flat_map do |route|
        next [ route ] unless stale?(route)

        recovery_data?(route) ? [ route.dup.tap { |r| r.retired = true } ] : []
      end
    end

    def order_active_first(routes)
      active, stale = routes.partition { |route| !stale?(route) }
      active + stale
    end

    def find_active_route(routes, hostname)
      routes.find { |route| route.hostname == hostname && !stale?(route) }
    end

    def normalize_patch(patch)
      patch.to_h.each_with_object({}) do |(key, value), out|
        reader = FIELDS.key(key.to_s) || key.to_sym
        next unless METADATA_FIELDS.include?(reader)

        out[reader] = value
      end
    end

    # Read and validate the routes file. Missing = empty table; unreadable or
    # corrupt raises RoutesFileError so callers never report it as empty.
    def read_route_file
      return [] unless File.exist?(@routes_path)

      begin
        raw = File.read(@routes_path)
      rescue SystemCallError => e
        raise RoutesFileError.new(@routes_path, :unreadable, "Could not read routes file #{@routes_path}: #{e.message}")
      end
      begin
        parsed = JSON.parse(raw)
      rescue JSON::ParserError
        raise RoutesFileError.new(@routes_path, :corrupt, "Corrupted routes file (invalid JSON): #{@routes_path}. Move it aside.")
      end
      unless parsed.is_a?(Array)
        raise RoutesFileError.new(@routes_path, :corrupt, "Corrupted routes file (expected array): #{@routes_path}. Move it aside.")
      end

      valid = parsed.select { |value| self.class.valid_route?(value) }
      @on_warning&.call("Skipped invalid route entries in #{@routes_path}") if valid.size != parsed.size
      order_active_first(valid.map { |hash| Route.from_h(hash) })
    end

    # Apply one change under the route lock. The block returns [value, changed].
    def mutate_routes(replace_skipped_hostname = nil)
      with_lock do
        routes = read_route_file
        value, changed = yield routes
        save_routes(retain_stale_records(routes), replace_skipped_hostname) if changed
        value
      end
    end

    def skipped_routes
      raw = begin
        File.read(@routes_path)
      rescue Errno::ENOENT
        return []
      end
      existing = JSON.parse(raw)
      existing.is_a?(Array) ? existing.reject { |value| self.class.valid_route?(value) } : []
    rescue JSON::ParserError
      []
    end

    def skipped_route?(hostname)
      skipped_routes.any? { |value| value.is_a?(Hash) && value["hostname"] == hostname }
    end

    # Atomic write: temp file + rename, so readers never see a partial table.
    def save_routes(routes, replace_skipped_hostname = nil)
      skipped = skipped_routes.reject do |value|
        replace_skipped_hostname && value.is_a?(Hash) && value["hostname"] == replace_skipped_hostname
      end
      temp_path = "#{@routes_path}.tmp"
      begin
        FileUtils.rm_f(temp_path)
        File.open(temp_path, File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) do |f|
          f.write(JSON.pretty_generate(order_active_first(routes).map(&:to_h) + skipped))
        end
        State.fix_ownership(temp_path)
        File.rename(temp_path, @routes_path)
      rescue StandardError
        FileUtils.rm_f(temp_path)
        raise
      end
    end

    def with_lock
      ensure_dir
      raise Error, "Failed to acquire route lock" unless acquire_lock

      begin
        yield
      ensure
        release_lock
      end
    end

    def acquire_lock
      deadline = monotonic + LOCK_TIMEOUT
      delay = LOCK_RETRY_BASE
      while monotonic < deadline
        begin
          Dir.mkdir(@lock_path)
          return true
        rescue Errno::EEXIST
          begin
            if Time.now - File.mtime(@lock_path) > STALE_LOCK_THRESHOLD
              FileUtils.rm_rf(@lock_path)
              next
            end
          rescue SystemCallError
            next
          end
        rescue SystemCallError
          return false
        end
        sleep(delay + rand * delay)
        delay = [ delay * 2, LOCK_RETRY_CAP ].min
      end
      false
    end

    def release_lock
      FileUtils.rm_rf(@lock_path)
    rescue StandardError
      nil
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
