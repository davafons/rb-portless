# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# State-dir resolution and safety checks (ported from utils.test.ts).
class StateTest < Minitest::Test
  S = Portless::State

  def home(env, macos: true, passwd: nil)
    S.resolve_user_home(env: env, windows: false, macos: macos, homedir: "/var/root", passwd_home: ->(_) { passwd })
  end

  # turbo.ts uses USER_STATE_DIR (~/.portless), not PORTLESS_STATE_DIR.
  def test_turbo_files_live_in_the_user_state_dir_whatever_the_override
    assert_equal File.join(Dir.home, ".rb-portless"), Portless::State.user_state_dir
    refute_equal Portless::State.dir, Portless::State.user_state_dir # test_helper overrides it
    assert_equal File.join(Dir.home, ".rb-portless", "turbo-env-loader.cjs"), Portless::Turbo.loader_path
    assert_equal File.join(Dir.home, ".rb-portless", "dev-manifest.json"), Portless::Turbo.manifest_path
  end

  def test_resolve_user_home
    assert_equal "/var/root", home({})
    assert_equal "/var/root", home({ "SUDO_USER" => "root" })
    assert_equal "/Users/dev", home({ "SUDO_USER" => "dev", "HOME" => "/Users/dev" })
    assert_equal "/srv/dev", home({ "SUDO_USER" => "dev", "HOME" => "/var/root" }, passwd: "/srv/dev")
    assert_equal "/Users/dev", home({ "SUDO_USER" => "dev", "HOME" => "/root" })
    assert_equal "/home/dev", home({ "SUDO_USER" => "dev" }, macos: false)
  end

  def test_dir_honours_override_and_sudo_user
    env = ENV.to_h
    ENV["PORTLESS_STATE_DIR"] = "/tmp/custom-state"
    assert_equal "/tmp/custom-state", S.dir
    ENV["PORTLESS_STATE_DIR"] = "rel/state"
    assert_equal "rel/state", S.dir, "used as given, like resolveStateDir"
    ENV.delete("PORTLESS_STATE_DIR")
    assert_equal File.join(Dir.home, ".rb-portless"), S.dir
  ensure
    ENV.replace(env)
  end

  def test_fix_ownership_lchowns_only_the_given_paths
    env = ENV.to_h
    ENV["SUDO_UID"] = "501"
    ENV["SUDO_GID"] = "20"
    calls = []
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "child"), "x")
      File.symlink(File.join(dir, "child"), File.join(dir, "link"))
      Process.stub(:uid, 0) do
        File.stub(:lchown, ->(*args) { calls << args }) do
          S.fix_ownership(dir, File.join(dir, "link"))
          S.fix_ownership
        end
      end
      assert_equal [ [ 501, 20, dir ] ], calls
    end
  ensure
    ENV.replace(env)
  end

  def test_safe_dir_has_no_problem
    Dir.mktmpdir do |dir|
      File.chmod(0o755, dir)
      assert_nil S.explain_unsafe_state_dir(dir)
      assert S.cleanable?(dir)
    end
  end

  def test_group_writable_dir_is_refused
    Dir.mktmpdir do |dir|
      File.chmod(0o775, dir)
      assert_equal "other users can write to it. Run: chmod go-w #{File.realpath(dir)}", S.explain_unsafe_state_dir(dir)
      err = assert_raises(Portless::Error) { S.require_state_dir(File.join(dir, "sub").tap { |d| Dir.mkdir(d, 0o777); File.chmod(0o777, d) }) }
      assert_match(/Cannot use state directory/, err.message)
    end
  end

  def test_unsafe_parent_is_refused
    Dir.mktmpdir do |dir|
      File.chmod(0o777, dir) # world-writable, no sticky bit
      child = File.join(dir, "state")
      Dir.mkdir(child, 0o755)
      assert_match(/other users can replace it through/, S.explain_unsafe_state_dir(child))
    end
  end

  def test_missing_and_non_directory
    Dir.mktmpdir do |dir|
      File.chmod(0o755, dir)
      assert_equal "it cannot be resolved", S.explain_unsafe_state_dir(File.join(dir, "nope"))
      file = File.join(dir, "file")
      File.write(file, "")
      assert_equal "it is not a directory", S.explain_unsafe_state_dir(file)
    end
  end

  def test_ensure_state_dir_creates_with_owner_only_mode
    Dir.mktmpdir do |dir|
      File.chmod(0o755, dir)
      target = File.join(dir, "new")
      assert_nil S.ensure_state_dir(target)
      assert_equal 0o755, File.stat(target).mode & 0o777
    end
  end

  def test_trusted_symlink_is_followed
    Dir.mktmpdir do |dir|
      File.chmod(0o755, dir)
      real = File.join(dir, "real")
      Dir.mkdir(real, 0o755)
      link = File.join(dir, "link")
      File.symlink(real, link)
      assert_nil S.explain_unsafe_state_dir(link)
    end
  end
end
