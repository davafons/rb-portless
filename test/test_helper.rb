# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

# Isolate every test run's state dir so we never touch ~/.rb-portless.
ENV["PORTLESS_STATE_DIR"] ||= File.join(Dir.tmpdir, "rb-portless-test-#{Process.pid}")

require_relative "../lib/rb-portless"
