# frozen_string_literal: true

require_relative "test_helper"

# spawnCommand port: shell execution, exit codes, signal forwarding, PATH.
class RunSupportTest < Minitest::Test
  R = Portless::RunSupport

  def test_exit_code_and_env_and_callbacks
    events = []
    code = nil
    out, = capture_subprocess_io do
      code = R.spawn_command([ "sh", "-c", "echo $FOO; exit 4" ], env: { "FOO" => "bar" },
                             on_spawn: ->(pid) { events << [ :spawn, pid.positive? ] },
                             on_exit: ->(_pid, c) { events << [ :exit, c ] },
                             on_cleanup: -> { events << [ :cleanup ] })
    end
    assert_equal 4, code
    assert_equal "bar\n", out
    assert_equal [ [ :spawn, true ], [ :exit, 4 ], [ :cleanup ] ], events
  end

  def test_args_are_shell_escaped
    out, = capture_subprocess_io { R.spawn_command([ "printf", "%s|", "a b", "it's", "$HOME" ]) }
    assert_equal "a b|it's|$HOME|", out
  end

  def test_term_is_forwarded_to_the_tree_and_exit_is_128_plus_signal
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "grandchild.pid")
      code = nil
      t = Thread.new do
        code = R.spawn_command([ "sh", "-c", "sleep 30 & echo $! > #{marker}; wait" ])
      end
      sleep 0.05 until File.exist?(marker) && !File.read(marker).empty?
      grandchild = File.read(marker).to_i
      Process.kill("TERM", Process.pid)
      t.join(10)
      assert_equal 143, code
      refute Portless::ProcessGroup.running?(grandchild), "grandchild must be gone"
    end
  end

  def test_augmented_path_prepends_node_modules_bin
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "node_modules", ".bin")
      FileUtils.mkdir_p(bin)
      sub = File.join(dir, "pkg")
      FileUtils.mkdir_p(sub)
      path = R.augmented_path({ "PATH" => "/usr/bin" }, sub)
      assert path.start_with?(File.realpath(bin)) || path.start_with?(bin)
      assert_includes path.split(File::PATH_SEPARATOR), "/usr/bin"
    end
  end
end
