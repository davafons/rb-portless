# frozen_string_literal: true

require_relative "test_helper"

class FrameworksTest < Minitest::Test
  def test_port_respecting_commands_are_left_alone
    assert_equal [ "bin/rails", "server" ], Portless::Frameworks.inject([ "bin/rails", "server" ], 4321)
    assert_equal [ "bin/dev" ], Portless::Frameworks.inject([ "bin/dev" ], 4321)
    assert_equal [ "node", "server.js" ], Portless::Frameworks.inject([ "node", "server.js" ], 4321)
  end

  def test_vite_gets_strict_port_and_host
    out = Portless::Frameworks.inject([ "vite" ], 4321)
    assert_equal [ "vite", "--port", "4321", "--strictPort", "--host", "127.0.0.1" ], out
  end

  def test_astro_gets_port_and_host_without_strict
    out = Portless::Frameworks.inject([ "astro", "dev" ], 4321)
    assert_includes out, "--port"
    assert_includes out, "4321"
    refute_includes out, "--strictPort"
  end

  def test_sees_through_package_runners
    out = Portless::Frameworks.inject([ "npx", "vite" ], 4321)
    assert_includes out, "--strictPort"
  end
end
