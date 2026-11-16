# frozen_string_literal: true

require "json"
require "fileutils"

module Portless
  # Turborepo integration: Turbo owns the child processes, so each package's
  # PORT/PORTLESS_URL travel through a manifest keyed by package dir, applied
  # by a Node `--require` loader. Mirrors portless's turbo.ts.
  module Turbo
    module_function

    LOADER_FILENAME = "turbo-env-loader.cjs"
    MANIFEST_FILENAME = "dev-manifest.json"

    def loader_path(base_dir = State.user_state_dir) = File.join(base_dir, LOADER_FILENAME)
    def manifest_path(base_dir = State.user_state_dir) = File.join(base_dir, MANIFEST_FILENAME)

    def loader_source(base_dir = State.user_state_dir)
      <<~JS
        "use strict";
        var fs = require("fs");
        var path = require("path");
        var manifestPath = path.join(#{JSON.generate(base_dir)}, "dev-manifest.json");
        try {
          var raw = fs.readFileSync(manifestPath, "utf-8");
          var manifest = JSON.parse(raw);
          var cwd = process.cwd();
          var entry = manifest[cwd];
          if (entry && typeof entry === "object") {
            var keys = Object.keys(entry);
            for (var i = 0; i < keys.length; i++) {
              process.env[keys[i]] = entry[keys[i]];
            }
          }
        } catch (_) {}
      JS
    end

    def ensure_env_loader(base_dir = State.user_state_dir)
      FileUtils.mkdir_p(base_dir, mode: 0o755)
      target = loader_path(base_dir)
      source = loader_source(base_dir)
      return if File.exist?(target) && File.read(target) == source

      File.write(target, source)
      File.chmod(0o644, target)
    end

    def write_manifest(entries, base_dir = State.user_state_dir)
      FileUtils.mkdir_p(base_dir, mode: 0o755)
      File.write(manifest_path(base_dir), "#{JSON.pretty_generate(entries)}\n")
      File.chmod(0o644, manifest_path(base_dir))
    end

    def remove_manifest(base_dir = State.user_state_dir)
      File.delete(manifest_path(base_dir))
    rescue StandardError
      nil
    end

    def build_node_options(base_dir = State.user_state_dir)
      existing = ENV["NODE_OPTIONS"].to_s
      lp = loader_path(base_dir)
      flag = lp.include?(" ") ? "--require \"#{lp}\"" : "--require #{lp}"
      existing.empty? ? flag : "#{flag} #{existing}"
    end

    def turbo_config?(ws_root)
      %w[turbo.json turbo.jsonc].any? { |name| File.readable?(File.join(ws_root, name)) }
    end
  end
end
