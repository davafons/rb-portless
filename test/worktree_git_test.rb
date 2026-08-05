# frozen_string_literal: true

require_relative "test_helper"

# Worktree.prefix against a real repository: the root checkout gets no prefix;
# a linked `git worktree add` on a feature branch gets the branch's last
# segment as a subdomain label.
class WorktreeGitTest < Minitest::Test
  def test_prefix_in_a_real_linked_worktree
    skip "git not available" unless Portless.which("git")

    Dir.mktmpdir do |dir|
      root = File.join(dir, "repo")
      linked = File.join(dir, "wt")
      # Isolate from the developer's global git config (signing, hooks, …).
      env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL,
              "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t",
              "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t" }
      git = ->(*args, chdir: root) { system(env, "git", "-C", chdir, *args, out: File::NULL, err: File::NULL) }

      Dir.mkdir(root)
      git.call("init", "-b", "main")
      git.call("commit", "--allow-empty", "-m", "init")

      assert_nil Portless::Worktree.prefix(root), "root checkout must get no prefix"

      git.call("worktree", "add", "-b", "feature/auth-flow", linked)
      assert_equal "auth-flow", Portless::Worktree.prefix(linked)
      assert_nil Portless::Worktree.prefix(root), "root stays unprefixed with a linked worktree present"
    end
  end
end
