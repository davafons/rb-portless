# frozen_string_literal: true

module Portless
  # Git-worktree-aware hostname prefix. In a *linked* worktree (one created via
  # `git worktree add`, not the root checkout) sitting on a non-default branch,
  # the branch's last path segment becomes a subdomain prefix so each worktree
  # gets its own URL — `feature/auth` → `auth.<name>.localhost`. Returns nil in
  # the root worktree, on main/master, on detached HEAD, or outside git.
  # Mirrors portless's detectWorktreePrefix (git-CLI path).
  module Worktree
    module_function

    DEFAULT_BRANCHES = %w[main master].freeze

    def prefix(dir = Dir.pwd)
      Portless.which("git") ? via_cli(dir) : via_filesystem(dir)
    rescue StandardError
      nil
    end

    # Authoritative path: ask git directly.
    def via_cli(dir)
      list = git(dir, "worktree", "list", "--porcelain")
      return nil if list.nil?
      return nil if list.lines.count { |l| l.start_with?("worktree ") } <= 1

      # Only a *linked* worktree gets a prefix: there --git-dir differs from
      # --git-common-dir; in the root worktree they're the same path.
      git_dir = git(dir, "rev-parse", "--git-dir")
      common  = git(dir, "rev-parse", "--git-common-dir")
      return nil if git_dir.nil? || common.nil?
      return nil if File.expand_path(git_dir, dir) == File.expand_path(common, dir)

      branch_to_prefix(git(dir, "rev-parse", "--abbrev-ref", "HEAD"))
    end

    # Fallback when the git binary isn't available: walk up for a `.git` *file*
    # (worktrees use a file, not a dir) whose gitdir points into /worktrees/, and
    # read the branch from that gitdir's HEAD. Submodules (/modules/) are ignored.
    def via_filesystem(dir)
      current = File.expand_path(dir)
      loop do
        git_path = File.join(current, ".git")
        return nil if File.directory?(git_path) # root checkout, not a worktree

        if File.file?(git_path)
          gitdir = File.read(git_path)[/^gitdir:\s*(.+)$/, 1]
          return nil unless gitdir&.match?(%r{[/\\]worktrees[/\\][^/\\]+$})

          head = File.read(File.join(File.expand_path(gitdir, current), "HEAD"))
          return branch_to_prefix(head[%r{^ref: refs/heads/(.+)$}, 1])
        end

        parent = File.dirname(current)
        return nil if parent == current

        current = parent
      end
    end

    # Last `/`-segment of the branch, sanitized; nil for default/detached HEAD.
    def branch_to_prefix(branch)
      return nil if branch.nil? || branch.empty? || branch == "HEAD"
      return nil if DEFAULT_BRANCHES.include?(branch)

      label = branch.split("/").last.to_s.downcase.gsub(/[^a-z0-9-]+/, "-").gsub(/\A-+|-+\z/, "")
      label.empty? ? nil : label
    end

    def git(dir, *args)
      out = IO.popen([ "git", "-C", dir, *args ], err: File::NULL, &:read)
      $?.success? ? out.strip : nil
    rescue StandardError
      nil
    end
  end
end
