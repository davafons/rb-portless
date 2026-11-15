# frozen_string_literal: true

require "json"

module Portless
  # Monorepo workspace discovery (pnpm-workspace.yaml or package.json
  # "workspaces"). Mirrors portless's workspace.ts.
  module Workspace
    module_function

    Package = Struct.new(:dir, :name, :scope, :scripts, keyword_init: true)

    def find_workspace_root(cwd = Dir.pwd)
      dir = File.expand_path(cwd)
      loop do
        return dir if File.readable?(File.join(dir, "pnpm-workspace.yaml"))
        return dir unless read_workspaces_from_package_json(dir).nil?

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    def detect_workspace_source(root)
      return "pnpm" if File.readable?(File.join(root, "pnpm-workspace.yaml"))
      return "package-json" unless read_workspaces_from_package_json(root).nil?

      nil
    end

    def read_workspaces_from_package_json(dir)
      pkg = JSON.parse(File.read(File.join(dir, "package.json")))
      return nil unless pkg.is_a?(Hash)

      ws = pkg["workspaces"]
      return ws.grep(String) if ws.is_a?(Array)
      return ws["packages"].grep(String) if ws.is_a?(Hash) && ws["packages"].is_a?(Array)

      nil
    rescue StandardError
      nil
    end

    def discover_workspace_packages(root)
      globs =
        case detect_workspace_source(root)
        when "pnpm"
          content = begin
            File.read(File.join(root, "pnpm-workspace.yaml"))
          rescue StandardError
            return []
          end
          parse_pnpm_workspace_yaml(content)
        when "package-json" then read_workspaces_from_package_json(root) || []
        else return []
        end

      expand_package_globs(root, globs).filter_map do |dir|
        pkg = JSON.parse(File.read(File.join(dir, "package.json")))
        raw = pkg["name"].is_a?(String) ? pkg["name"] : nil
        scripts = pkg["scripts"].is_a?(Hash) ? pkg["scripts"] : {}
        Package.new(dir: dir, name: raw&.sub(%r{\A@[^/]+/}, ""), scope: raw&.[](%r{\A@([^/]+)/}, 1),
                    scripts: scripts)
      rescue StandardError
        nil
      end
    end

    def parse_pnpm_workspace_yaml(content)
      globs = []
      in_packages = false
      content.split("\n").each do |raw|
        line = raw.rstrip
        if (header = line.match(/\Apackages\s*:(.*)/))
          rest = header[1].strip
          return parse_flow_sequence(rest) if rest.start_with?("[")

          in_packages = true
          next
        end
        next unless in_packages
        break if !line.empty? && !line.start_with?(" ", "\t", "-")

        trimmed = line.strip
        next if trimmed.empty? || trimmed.start_with?("#")

        if (m = trimmed.match(/\A-\s+['"]?([^'"#]+?)['"]?\s*(?:#.*)?\z/))
          glob = m[1].strip
          globs << glob unless glob.empty?
        end
      end
      globs
    end

    def parse_flow_sequence(input)
      input.sub(/\A\[/, "").sub(/\]\s*\z/, "").split(",")
           .map { |s| s.strip.sub(/\A['"]/, "").sub(/['"]\z/, "").strip }.reject(&:empty?)
    end

    def expand_package_globs(root, globs)
      included = []
      excluded = []
      globs.each do |glob|
        if glob.start_with?("!")
          excluded.concat(expand_segments(root, glob[1..].split("/")))
        else
          included.concat(expand_segments(root, glob.split("/")))
        end
      end
      (included.uniq - excluded).sort
    end

    def segment_matches?(pattern, name)
      return true if %w[* **].include?(pattern)

      star = pattern.index("*")
      return pattern == name unless star

      name.start_with?(pattern[0...star]) && name.end_with?(pattern[(star + 1)..].sub(/\*+\z/, ""))
    end

    def expand_segments(base, segments)
      return File.directory?(base) ? [ base ] : [] if segments.empty?

      current, *rest = segments
      return expand_segments(File.join(base, current), rest) unless current.include?("*")

      matched = Dir.children(base).select do |e|
        File.directory?(File.join(base, e)) && segment_matches?(current, e)
      end
      matched.flat_map do |e|
        rest.empty? ? [ File.join(base, e) ] : expand_segments(File.join(base, e), rest)
      end
    rescue StandardError
      []
    end
  end
end
