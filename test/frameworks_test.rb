# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Ported from portless cli-utils.test.ts (injectFrameworkFlags,
# injectPackageScriptFrameworkFlags, isUnsafeToAppendArgs,
# resolveFrameworkBasename, script forwarding).
class FrameworksTest < Minitest::Test
  F = Portless::Frameworks

  def run_inject(args, port = 4567)
    args = args.dup
    F.inject_framework_flags(args, port)
    args
  end

  def setup = ENV.delete("PORTLESS_LAN")

  def test_vite_gets_port_strict_port_and_host
    assert_equal %w[vite dev --port 4567 --strictPort --host 127.0.0.1], run_inject(%w[vite dev])
    assert_equal %w[./node_modules/.bin/vite --port 4000 --strictPort --host 127.0.0.1],
                 run_inject(%w[./node_modules/.bin/vite], 4000)
  end

  def test_existing_flags_suppress_their_own_injection_only
    assert_equal %w[vite dev --port 3000 --host 127.0.0.1], run_inject(%w[vite dev --port 3000])
    assert_equal %w[vite dev --port=3000 --host=0.0.0.0], run_inject(%w[vite dev --port=3000 --host=0.0.0.0])
    assert_equal %w[vite dev --host 0.0.0.0 --port 4567 --strictPort], run_inject(%w[vite dev --host 0.0.0.0])
  end

  def test_build_and_other_non_server_subcommands_get_nothing
    assert_equal %w[vite build], run_inject(%w[vite build])
    assert_equal %w[vite optimize], run_inject(%w[vite optimize])
    assert_equal %w[astro build], run_inject(%w[astro build])
    assert_equal %w[vitepress build], run_inject(%w[vitepress build])
    assert_equal %w[bunx --bun vite optimize], run_inject(%w[bunx --bun vite optimize])
  end

  def test_framework_table
    assert_equal %w[vp dev --port 4567 --strictPort --host 127.0.0.1], run_inject(%w[vp dev])
    assert_equal %w[react-router dev --port 4567 --strictPort --host 127.0.0.1], run_inject(%w[react-router dev])
    assert_equal %w[vitepress dev --port 4567 --strictPort --host 127.0.0.1], run_inject(%w[vitepress dev])
    assert_equal %w[rsbuild dev --port 4567 --host 127.0.0.1], run_inject(%w[rsbuild dev])
    assert_equal %w[astro dev --port 4567 --host 127.0.0.1], run_inject(%w[astro dev])
    assert_equal %w[ng serve --port 4567 --host 127.0.0.1], run_inject(%w[ng serve])
    assert_equal %w[react-native start --port 4567 --host 127.0.0.1], run_inject(%w[react-native start])
    assert_equal %w[expo start --port 4567 --host localhost], run_inject(%w[expo start])
    assert_equal %w[wrangler dev --port 4567 --ip 127.0.0.1], run_inject(%w[wrangler dev])
    assert_equal %w[wrangler dev --ip=0.0.0.0 --port 4567], run_inject(%w[wrangler dev --ip=0.0.0.0])
  end

  def test_expo_lan_skips_host
    ENV["PORTLESS_LAN"] = "1"
    assert_equal %w[expo start --port 4567], run_inject(%w[expo start])
  ensure
    ENV.delete("PORTLESS_LAN")
  end

  def test_frameworks_reading_port_are_untouched
    assert_equal %w[next dev], run_inject(%w[next dev])
    assert_equal %w[node server.js], run_inject(%w[node server.js])
    assert_equal [], run_inject([])
  end

  def test_package_runners
    assert_equal %w[npx vite dev --port 4567 --strictPort --host 127.0.0.1], run_inject(%w[npx vite dev])
    assert_equal %w[bunx --bun vite --port 4567 --strictPort --host 127.0.0.1], run_inject(%w[bunx --bun vite])
    assert_equal %w[pnpm exec vite --port 4567 --strictPort --host 127.0.0.1], run_inject(%w[pnpm exec vite])
    assert_equal %w[npm exec vite -- --port 4567 --strictPort --host 127.0.0.1], run_inject(%w[npm exec vite])
  end

  def test_astro_global_flag_before_subcommand
    assert_equal %w[astro --root app dev --port 4567 --host 127.0.0.1], run_inject(%w[astro --root app dev])
    assert_equal %w[vite --mode dev build], run_inject(%w[vite --mode dev build])
  end

  def test_unsafe_to_append_args
    %w[a&&b a||b a;b a|b].each { |s| assert F.unsafe_to_append_args?("vite dev #{s}"), s }
    assert F.unsafe_to_append_args?("vite dev # comment")
    assert F.unsafe_to_append_args?("vite dev\nnode x")
    assert F.unsafe_to_append_args?("vite dev &> out.log")
    refute F.unsafe_to_append_args?("vite dev 2>&1")
    refute F.unsafe_to_append_args?("vite --open '/foo&bar'")
    refute F.unsafe_to_append_args?("vite --tag v1#2")
    refute F.unsafe_to_append_args?("vite dev")
  end

  def with_pkg(scripts, extra = {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "package.json"), JSON.generate({ "scripts" => scripts }.merge(extra)))
      yield dir
    end
  end

  def test_package_script_injection_through_pm_run
    with_pkg("dev" => "vite dev") do |dir|
      args = %w[bun run dev]
      F.inject_package_script_framework_flags(args, 4567, dir)
      assert_equal %w[bun run dev --port 4567 --strictPort --host 127.0.0.1], args
      args = %w[npm run dev]
      F.inject_package_script_framework_flags(args, 4567, dir)
      assert_equal %w[npm run dev -- --port 4567 --strictPort --host 127.0.0.1], args
      args = %w[npm run dev -- --port 3000]
      F.inject_package_script_framework_flags(args, 4567, dir)
      assert_equal %w[npm run dev -- --port 3000 --host 127.0.0.1], args
    end
  end

  def test_package_script_injection_skips_compound_and_build_scripts
    with_pkg("dev" => "vite dev && node x", "build" => "vite build") do |dir|
      args = %w[pnpm run dev]
      F.inject_package_script_framework_flags(args, 4567, dir)
      assert_equal %w[pnpm run dev], args
      args = %w[pnpm run build]
      F.inject_package_script_framework_flags(args, 4567, dir)
      assert_equal %w[pnpm run build], args
    end
  end

  def test_resolve_framework_basename_through_scripts
    with_pkg("dev" => "expo start") do |dir|
      assert_equal "expo", F.resolve_framework_basename(%w[bun run dev], dir)
      assert_equal "vite", F.resolve_framework_basename(%w[npx vite], dir)
      assert_nil F.resolve_framework_basename(%w[next dev], dir)
    end
  end

  def test_script_arg_forwarding_counts_separators
    with_pkg({ "dev" => "vite", "wrapped" => "npm run dev", "bad" => "a && b", "loop" => "npm run loop" },
             "packageManager" => "npm@10") do |dir|
      assert_equal({ kind: "forward", separators: 0 }, F.resolve_script_arg_forwarding("dev", dir))
      assert_equal({ kind: "forward", separators: 1 }, F.resolve_script_arg_forwarding("wrapped", dir))
      assert_equal({ kind: "unsafe", script_name: "bad" }, F.resolve_script_arg_forwarding("bad", dir))
      assert_equal({ kind: "missing" }, F.resolve_script_arg_forwarding("nope", dir))
      assert_equal({ kind: "forward", separators: 1 }, F.resolve_script_arg_forwarding("loop", dir))
    end
  end

  def test_turbo_root_forwarding
    with_pkg({ "dev" => "turbo run dev", "plain" => "vite" }, "packageManager" => "pnpm@9") do |dir|
      assert_equal({ kind: "forward", separators: 1 }, F.resolve_turbo_root_forwarding("dev", dir))
      assert_equal({ kind: "none" }, F.resolve_turbo_root_forwarding("plain", dir))
    end
  end
end
