# frozen_string_literal: true

require "digest"
require "json"
require "open3"

module Portless
  # Project-name inference, hostname sanitization and git-worktree prefixes.
  # Mirrors portless's auto.ts function-for-function.
  module Auto
    module_function

    MAX_DNS_LABEL_LENGTH = 63
    DEFAULT_BRANCHES = %w[main master].freeze

    InferredName = Struct.new(:name, :source)
    WorktreePrefix = Struct.new(:prefix, :source)

    # Truncate a DNS label to 63 chars, appending a 6-char sha256 suffix of
    # the full label so truncated names stay unique.
    def truncate_label(label)
      return label if label.length <= MAX_DNS_LABEL_LENGTH

      hash = Digest::SHA256.hexdigest(label)[0, 6]
      prefix = label[0, MAX_DNS_LABEL_LENGTH - 7].sub(/-+\z/, "")
      "#{prefix}-#{hash}"
    end

    def sanitize_for_hostname(name)
      sanitized = name.to_s.downcase.gsub(/[^a-z0-9-]/, "-").gsub(/-{2,}/, "-").gsub(/\A-+|-+\z/, "")
      truncate_label(sanitized)
    end

    # package.json name (minus @scope/), then git root basename, then cwd basename.
    def infer_project_name(cwd = Dir.pwd)
      if (pkg = find_package_json_name(cwd))
        sanitized = sanitize_for_hostname(pkg)
        return InferredName.new(sanitized, "package.json") unless sanitized.empty?
      end

      if (git_root = find_git_root(cwd))
        sanitized = sanitize_for_hostname(File.basename(git_root))
        return InferredName.new(sanitized, "git root") unless sanitized.empty?
      end

      sanitized = sanitize_for_hostname(File.basename(cwd))
      return InferredName.new(sanitized, "directory name") unless sanitized.empty?

      raise Error, "Could not infer a project name from package.json, git root, or directory name"
    end

    def find_package_json_name(start_dir)
      each_ancestor(start_dir) do |dir|
        pkg = JSON.parse(File.read(File.join(dir, "package.json")))
        name = pkg["name"] if pkg.is_a?(Hash)
        return name.sub(%r{\A@[^/]+/}, "") if name.is_a?(String) && !name.empty?
      rescue StandardError
        next
      end
      nil
    end

    def find_git_root(start_dir)
      toplevel = git(start_dir, "rev-parse", "--show-toplevel")
      return toplevel if toplevel && !toplevel.empty?

      each_ancestor(start_dir) do |dir|
        return dir if File.exist?(File.join(dir, ".git"))
      end
      nil
    end

    def apply_worktree_prefix(base_name, worktree, template = nil)
      return base_name unless worktree
      if template
        return template.gsub("{worktree}", worktree.prefix).gsub("{name}", base_name)
                       .split(".", -1).map { |label| truncate_label(label.downcase) }.join(".")
      end

      "#{worktree.prefix}.#{base_name}"
    end

    def branch_to_prefix(branch, style)
      return nil if branch.nil? || branch.empty? || branch == "HEAD" || DEFAULT_BRANCHES.include?(branch)

      label = style == "branch" ? branch : branch.split("/").last
      prefix = sanitize_for_hostname(label.to_s)
      prefix.empty? ? nil : prefix
    end

    # PORTLESS_PREFIX (even empty) overrides detection.
    def detect_worktree_prefix(cwd = Dir.pwd, style = "last-segment")
      style ||= "last-segment"
      if ENV.key?("PORTLESS_PREFIX")
        prefix = sanitize_for_hostname(ENV["PORTLESS_PREFIX"])
        return prefix.empty? ? nil : WorktreePrefix.new(prefix, "PORTLESS_PREFIX")
      end

      result = detect_worktree_via_cli(cwd, style)
      return result unless result == :unavailable

      detect_worktree_via_filesystem(cwd, style)
    end

    # :unavailable when git can't answer (caller falls back to the filesystem).
    def detect_worktree_via_cli(cwd, style)
      list = git(cwd, "worktree", "list", "--porcelain")
      return :unavailable if list.nil?
      return nil if list.lines.count { |l| l.start_with?("worktree ") } <= 1

      git_dir = git(cwd, "rev-parse", "--git-dir")
      common = git(cwd, "rev-parse", "--git-common-dir")
      return :unavailable if git_dir.nil? || common.nil?
      return nil if File.expand_path(git_dir, cwd) == File.expand_path(common, cwd)

      branch = git(cwd, "rev-parse", "--abbrev-ref", "HEAD")
      return :unavailable if branch.nil?

      prefix = branch_to_prefix(branch, style)
      prefix ? WorktreePrefix.new(prefix, "git branch") : nil
    end

    def detect_worktree_via_filesystem(start_dir, style)
      each_ancestor(start_dir) do |dir|
        git_path = File.join(dir, ".git")
        return nil if File.directory?(git_path)
        next unless File.file?(git_path)

        match = File.read(git_path).strip.match(/\Agitdir:\s*(.+)\z/)
        return nil unless match

        gitdir = match[1]
        return nil unless gitdir.match?(%r{[/\\]worktrees[/\\][^/\\]+\z})

        prefix = branch_to_prefix(read_branch_from_head(File.expand_path(gitdir, dir)).to_s, style)
        return prefix ? WorktreePrefix.new(prefix, "git branch") : nil
      rescue StandardError
        next
      end
      nil
    end

    def read_branch_from_head(gitdir)
      File.read(File.join(gitdir, "HEAD")).strip[%r{\Aref: refs/heads/(.+)\z}, 1]
    rescue StandardError
      nil
    end

    def each_ancestor(start_dir)
      dir = File.expand_path(start_dir)
      loop do
        yield dir
        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end
    end

    def git(dir, *args)
      out, status = Open3.capture2("git", *args, chdir: dir, err: File::NULL)
      status.success? ? out.strip : nil
    rescue StandardError
      nil
    end
  end
end
