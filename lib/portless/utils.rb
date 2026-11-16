# frozen_string_literal: true

require "socket"

module Portless
  # Pure helpers shared by the CLI, proxy pages and daemon: port/URL/hostname
  # parsing and the TLD rules. Mirrors portless's utils.ts (parsePort,
  # formatUrl, formatUptime, parseHostname[s]) and the TLD helpers of
  # cli-utils.ts (validateTld, parseTldList, getRiskyTldReason, getDefaultTlds).
  module Utils
    module_function

    DEFAULT_TLD = "localhost"

    RISKY_TLDS = {
      "local" => "conflicts with mDNS/Bonjour on macOS",
      "dev" => "Google-owned; browsers force HTTPS via preloaded HSTS",
      "app" => "Google-owned; browsers force HTTPS via preloaded HSTS",
      "com" => "public TLD; DNS requests will leak to the internet",
      "org" => "public TLD; DNS requests will leak to the internet",
      "net" => "public TLD; DNS requests will leak to the internet",
      "io" => "public TLD; DNS requests will leak to the internet",
      "edu" => "public TLD; DNS requests will leak to the internet",
      "gov" => "public TLD; DNS requests will leak to the internet",
      "mil" => "public TLD; DNS requests will leak to the internet",
      "int" => "public TLD; DNS requests will leak to the internet"
    }.freeze

    SUFFIX_RISKY_TLDS = %w[local dev app].freeze

    # ICU root collation order for spaces and punctuation, before digits and
    # letters.
    COLLATION_PUNCTUATION = " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$"

    # Sort key emulating JS String#localeCompare (ICU root collation) for
    # labels: punctuation < digits < letters, case and accents only break ties
    # (unaccented first, then lowercase first).
    def locale_compare_key(text)
      chars = text.to_s.unicode_normalize(:nfd).scan(/\X/)
      primary = chars.map do |c|
        base = c[0]
        if (i = COLLATION_PUNCTUATION.index(base)) then [ 0, i ]
        elsif base.match?(/\d/) then [ 1, base ]
        else [ 2, base.downcase ]
        end
      end
      [ primary, chars.map { |c| c.length > 1 ? 1 : 0 }, chars.map { |c| c[0] == c[0].downcase ? 0 : 1 } ]
    end

    # A RouteStore that prints its warnings in yellow on stderr (upstream's
    # `new RouteStore(dir, { onWarning: (msg) => console.warn(colors.yellow(msg)) })`).
    def new_route_store(dir)
      RouteStore.new(dir, on_warning: ->(msg) { warn Colors.yellow(msg, io: $stderr) })
    end

    LOOPBACK_HOSTS = [ "127.0.0.1", "::1" ].freeze

    # Race both literal loopback addresses and hand the first connected socket
    # to the block (`error` nil). Returns a cancel lambda that aborts pending
    # attempts with ECANCELED (upstream: ABORT_ERR). utils.ts
    # createLoopbackConnection.
    def create_loopback_connection(port, &callback)
      lock = Mutex.new
      settled = false
      errors = []
      attempts = []
      finish = lambda do |error, socket = nil|
        won = lock.synchronize { settled ? false : (settled = true) }
        next false unless won

        attempts.each { |thread| thread.kill unless thread == Thread.current }
        callback.call(error, socket)
        true
      end
      LOOPBACK_HOSTS.each_with_index do |host, index|
        attempts << Thread.new do
          socket = Socket.tcp(host, port)
          socket.close unless finish.call(nil, socket)
        rescue StandardError => e
          both = lock.synchronize do
            errors[index] = e
            errors.compact.size == LOOPBACK_HOSTS.size
          end
          finish.call(errors[0]) if both
        end
      end
      -> { finish.call(Errno::ECANCELED.new("The operation was aborted")) }
    end

    def parse_port(value)
      trimmed = value.to_s.strip
      return nil unless trimmed.match?(/\A\d+\z/)

      port = trimmed.to_i
      port.between?(1, 65_535) ? port : nil
    end

    def format_url(hostname, proxy_port, tls = false)
      proto = tls ? "https" : "http"
      default_port = tls ? 443 : 80
      proxy_port == default_port ? "#{proto}://#{hostname}" : "#{proto}://#{hostname}:#{proxy_port}"
    end

    # registered_at and now are epoch milliseconds (routes.json registeredAt).
    def format_uptime(registered_at, now)
      return nil unless registered_at.is_a?(Numeric) && registered_at.finite? && registered_at.positive?

      elapsed = now - registered_at
      return nil if elapsed < -60_000

      seconds = ([ elapsed, 0 ].max / 1000).floor
      return "#{seconds}s" if seconds < 60

      minutes = seconds / 60
      return "#{minutes}m" if minutes < 60

      hours = minutes / 60
      return "#{hours}h" if hours < 24

      "#{hours / 24}d"
    end

    def strip_input(input)
      input.to_s.strip.sub(%r{\Ahttps?://}i, "").split("/").first.to_s.downcase
    end

    def parse_hostname(input, tld = DEFAULT_TLD)
      suffix = ".#{tld}"
      hostname = strip_input(input)
      hostname = hostname.delete_suffix(".localhost") if tld != "localhost" && hostname.end_with?(".localhost")
      raise Error, "Hostname cannot be empty" if hostname.empty? || hostname == suffix

      hostname = "#{hostname}#{suffix}" unless hostname.end_with?(suffix)
      name = hostname[0...-suffix.length]
      raise Error, "Invalid hostname \"#{name}\": consecutive dots are not allowed" if name.include?("..")
      unless name.match?(/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/)
        raise Error, "Invalid hostname \"#{name}\": must contain only lowercase letters, digits, hyphens, and dots"
      end

      name.split(".").each do |label|
        next if label.length <= 63

        raise Error, "Invalid hostname \"#{name}\": label \"#{label}\" exceeds 63-character DNS limit"
      end
      raise Error, "Invalid hostname \"#{hostname}\": exceeds 253-character DNS limit" if hostname.length > 253

      hostname
    end

    # Expand a name into one hostname per configured TLD (or only target_tlds).
    # A TLD that fails for TLD-specific reasons is skipped with a warning; we
    # raise only when none survive.
    def parse_hostnames(input, tlds = [ DEFAULT_TLD ], target_tlds = nil)
      unique = tlds.uniq
      expand = target_tlds && !target_tlds.empty? ? unique.select { |t| target_tlds.include?(t) } : unique
      base = strip_input(input)
      unique.sort_by { |t| -t.length }.each do |tld|
        suffix = ".#{tld}"
        if base.end_with?(suffix)
          base = base[0...-suffix.length]
          break
        end
      end

      hostnames = []
      skipped = []
      first_error = nil
      expand.each do |tld|
        hostnames << parse_hostname(base, tld)
      rescue Error => e
        first_error ||= e
        skipped << "\"#{tld}\": #{e.message}"
      end
      raise(first_error || Error.new("No usable TLD remains")) if hostnames.empty?

      skipped.each { |detail| warn "Warning: skipping TLD #{detail}" }
      hostnames
    end

    def risky_tld_reason(tld)
      exact = RISKY_TLDS[tld]
      return exact if exact

      SUFFIX_RISKY_TLDS.each { |risky| return RISKY_TLDS[risky] if tld.end_with?(".#{risky}") }
      nil
    end

    def validate_tld(tld)
      return "TLD cannot be empty" if tld.nil? || tld.empty?
      return "Invalid TLD \"#{tld}\": exceeds 253-character DNS limit" if tld.length > 253

      tld.split(".", -1).each do |label|
        return "Invalid TLD \"#{tld}\": labels cannot be empty" if label.empty?
        return "Invalid TLD \"#{tld}\": label \"#{label}\" exceeds 63-character DNS limit" if label.length > 63
        unless label.match?(/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/)
          return "Invalid TLD \"#{tld}\": labels must contain only lowercase letters, digits, and interior hyphens"
        end
      end
      nil
    end

    def parse_tld_list(value, source = "TLD")
      trimmed = value.to_s.strip
      return [] if trimmed.empty?

      trimmed.split(",", -1).each_with_object([]) do |raw, tlds|
        tld = raw.strip.downcase
        err = validate_tld(tld)
        raise Error, (source == "TLD" ? err : "#{source}: #{err}") if err

        tlds << tld unless tlds.include?(tld)
      end
    end

    def default_tlds
      val = ENV["PORTLESS_TLD"].to_s.strip.downcase
      return [ DEFAULT_TLD ] if val.empty?

      tlds = parse_tld_list(val, "PORTLESS_TLD")
      tlds.empty? ? [ DEFAULT_TLD ] : tlds
    end

    def env_enabled?(name)
      %w[1 true].include?(ENV[name])
    end

    def https_env_disabled? = %w[0 false].include?(ENV["PORTLESS_HTTPS"])
    def wildcard_env_enabled? = env_enabled?("PORTLESS_WILDCARD")
    def lan_env_enabled? = env_enabled?("PORTLESS_LAN")
    def unprivileged_env_enabled? = env_enabled?("PORTLESS_UNPRIVILEGED")
  end
end
