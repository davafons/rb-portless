# frozen_string_literal: true

require "json"

module Portless
  # Per-project config: an optional portless.json (or portless.yml) plus inferred
  # defaults. Mirrors portless's config.ts/auto.ts: name is inferred from the
  # config, the git root, or the directory; tld defaults to "localhost".
  class Config
    attr_reader :name, :tld, :app_port, :tls, :apps

    def self.load(dir = Dir.pwd)
      new(read_file(dir), dir)
    end

    def initialize(data, dir = Dir.pwd)
      @dir = dir
      @name = sanitize_label(data["name"] || infer_name(dir))
      @tld = (data["tld"] || Constants::DEFAULT_TLD).to_s
      @app_port = data["appPort"] || data["app_port"]
      @tls = data.fetch("tls", true)
      # Monorepo: { "apps": { "web": "bin/rails server", "api": "node api.js" } }.
      @apps = (data["apps"] || {}).transform_keys { |k| sanitize_label(k) }
    end

    # The full hostname an app registers (e.g. "shirabe.org.localhost" when tld is
    # set to that, or "<name>.localhost" by default). `name` overrides the base
    # (used by --name); `worktree:` prepends the git-worktree branch prefix so a
    # linked worktree gets its own URL (`auth.<name>.localhost`).
    def hostname(name = nil, worktree: true)
      base = name ? sanitize_label(name) : @name
      host = tld.split(".").include?(base) ? tld : "#{base}.#{tld}"
      prefix = worktree ? worktree_prefix : nil
      prefix ? "#{prefix}.#{host}" : host
    end

    # The git-worktree subdomain prefix for this project dir (nil if none).
    # Memoized — it shells out to git.
    def worktree_prefix
      return @worktree_prefix if defined?(@worktree_prefix)

      @worktree_prefix = Worktree.prefix(@dir)
    end

    # Real/reserved TLDs that can intercept live traffic or clash with mDNS.
    RISKY_TLDS = %w[dev app page zip mov local].freeze

    # A warning string if the tld looks risky, else nil. (.localhost / .test are safe.)
    def tld_warning
      last = tld.split(".").last
      return unless RISKY_TLDS.include?(last)

      "tld \".#{last}\" is a real/reserved TLD — prefer \".localhost\" so you don't intercept real traffic"
    end

    def self.read_file(dir)
      json = File.join(dir, "portless.json")
      return JSON.parse(File.read(json)) if File.exist?(json)

      {}
    rescue JSON::ParserError => e
      raise Error, "invalid portless.json: #{e.message}"
    end

    private

    def infer_name(dir)
      git_root = find_git_root(dir)
      File.basename(git_root || dir)
    end

    def find_git_root(dir)
      current = File.expand_path(dir)
      until current == "/"
        return current if File.directory?(File.join(current, ".git"))
        current = File.dirname(current)
      end
      nil
    end

    # A valid DNS label: lowercase alnum + hyphens, trimmed.
    def sanitize_label(value)
      label = value.to_s.downcase.gsub(/[^a-z0-9-]+/, "-").gsub(/\A-+|-+\z/, "")
      label.empty? ? "app" : label
    end
  end
end
