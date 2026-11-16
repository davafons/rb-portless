# frozen_string_literal: true

require "resolv"
require "socket"

module Portless
  # /etc/hosts management for resolvers that don't special-case .localhost
  # (Safari, custom TLDs). Entries live in a fenced block that is rewritten
  # only when it differs and verified by re-reading. Mirrors portless's
  # hosts.ts; the markers are "# rb-portless-start/end" so both tools can
  # keep their own block.
  module Hosts
    module_function

    LOOPBACK_ADDRESS = "127.0.0.1"
    MARKER_START = Constants::HOSTS_BEGIN
    MARKER_END = Constants::HOSTS_END
    DEFAULT_PATH = if Constants::WINDOWS
                     File.join(ENV.fetch("SystemRoot", "C:\\Windows"), "System32", "drivers", "etc", "hosts")
    else
                     "/etc/hosts"
    end

    class << self
      # Test seam (upstream mocks fs); never set from the environment.
      attr_writer :hosts_path

      def hosts_path = @hosts_path || DEFAULT_PATH
    end

    # Display name for the hosts file in user-facing text.
    def hosts_display = Constants::WINDOWS ? "hosts file" : "/etc/hosts"

    # Current content, or nil when the file cannot be read.
    def read_hosts_file
      File.read(hosts_path)
    rescue StandardError
      nil
    end

    # Lines between the markers (exclusive), stripped and non-empty.
    def extract_managed_block(content)
      start_idx = content.index(MARKER_START)
      end_idx = content.index(MARKER_END)
      return [] if start_idx.nil? || end_idx.nil? || end_idx <= start_idx

      content[(start_idx + MARKER_START.length)...end_idx].split("\n").map(&:strip).reject(&:empty?)
    end

    # Content without the managed block, trailing newlines normalized.
    def remove_block(content)
      start_idx = content.index(MARKER_START)
      end_idx = content.index(MARKER_END)
      return content if start_idx.nil? || end_idx.nil?

      before = content[0...start_idx]
      after = content[(end_idx + MARKER_END.length)..]
      "#{(before + after).gsub(/\n{3,}/, "\n\n").rstrip}\n"
    end

    def build_block(hostnames)
      return "" if hostnames.empty?

      entries = hostnames.map { |h| "#{LOOPBACK_ADDRESS} #{h}" }.join("\n")
      "#{MARKER_START}\n#{entries}\n#{MARKER_END}"
    end

    # Disabled only when PORTLESS_SYNC_HOSTS is "0" or "false" (opt-out).
    def should_auto_sync_hosts?(value) = value != "0" && value != "false"

    # Whether the managed block is exactly these hostnames, each on loopback.
    def block_matches_hostnames?(content, hostnames)
      wanted = hostnames.uniq
      return false if wanted.size != hostnames.size

      seen = []
      extract_managed_block(content).each do |line|
        address, *aliases = line.split("#", 2).first.strip.split(/\s+/)
        return false if address != LOOPBACK_ADDRESS || aliases.empty?

        aliases.each do |hostname|
          return false if !wanted.include?(hostname) || seen.include?(hostname)

          seen << hostname
        end
      end
      seen.size == wanted.size
    end

    # Rewrite the block to exactly these hostnames (needs privilege). Returns
    # whether the block matches afterwards; skips the write when it already does.
    def sync_hosts_file(hostnames)
      content = read_hosts_file
      return false if content.nil?
      return true if block_matches_hostnames?(content, hostnames)

      begin
        cleaned = remove_block(content)
        File.write(hosts_path, hostnames.empty? ? cleaned : "#{cleaned.rstrip}\n\n#{build_block(hostnames)}\n")
      rescue StandardError
        return false
      end
      verification = read_hosts_file
      !verification.nil? && block_matches_hostnames?(verification, hostnames)
    end

    def clean_hosts_file
      content = read_hosts_file
      return false if content.nil?
      return true unless content.include?(MARKER_START)

      File.write(hosts_path, remove_block(content))
      true
    rescue StandardError
      false
    end

    # Hostnames currently in the managed block (best effort: [] on read failure).
    def get_managed_hostnames
      content = read_hosts_file
      return [] if content.nil?

      extract_managed_block(content).flat_map { |line| line.split("#", 2).first.strip.split(/\s+/).drop(1) }
    end

    # Whether the system resolver picks an address where the local proxy listens.
    def check_host_resolution(hostname)
      address = Addrinfo.getaddrinfo(hostname, nil, nil, :STREAM).first&.ip_address
      [ "127.0.0.1", "::1" ].include?(address)
    rescue StandardError
      false
    end
  end
end
