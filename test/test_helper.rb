# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

# Never touch the real home directory: `clean` and other commands also sweep
# ~/.rb-portless, so every test (and every CLI/daemon it spawns) gets an empty
# temp HOME and its own state dir, whatever the developer's environment says.
TEST_ROOT = File.join(Dir.tmpdir, "rb-portless-test-#{Process.pid}")
ENV["HOME"] = File.join(TEST_ROOT, "home")
ENV["PORTLESS_STATE_DIR"] = File.join(TEST_ROOT, "state")
Dir.mkdir(TEST_ROOT) unless Dir.exist?(TEST_ROOT)
Dir.mkdir(ENV["HOME"]) unless Dir.exist?(ENV["HOME"])

# Never touch the real machine from tests: shims that refuse trust-store
# changes and sudo, inherited by every spawned CLI/daemon.
ENV["PATH"] = [ File.expand_path("support/bin", __dir__), ENV["PATH"] ].join(File::PATH_SEPARATOR)

require_relative "../lib/rb-portless"
