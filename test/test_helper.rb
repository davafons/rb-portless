# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

# Isolate every test run's state dir so we never touch ~/.rb-portless.
ENV["PORTLESS_STATE_DIR"] ||= File.join(Dir.tmpdir, "rb-portless-test-#{Process.pid}")

# Never touch the real machine from tests: shims that refuse trust-store
# changes and sudo, inherited by every spawned CLI/daemon.
ENV["PATH"] = [ File.expand_path("support/bin", __dir__), ENV["PATH"] ].join(File::PATH_SEPARATOR)

require_relative "../lib/rb-portless"
