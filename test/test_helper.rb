# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

# Isolate every test run's state dir so we never touch ~/.portless-rb.
ENV["PORTLESS_STATE_DIR"] ||= File.join(Dir.tmpdir, "portless-rb-test-#{Process.pid}")

require_relative "../lib/portless-rb"
