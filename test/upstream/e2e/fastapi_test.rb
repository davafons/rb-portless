# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/fastapi.test.ts

describe "fastapi" do
  include UpstreamE2E

  it "serves through the proxy" do
    skip "fixture toolchain not installed" unless File.exist?(UpstreamE2E::PYTHON_BIN)

    start_app(
      name: "fastapi-test",
      command: [ UpstreamE2E::PYTHON_BIN, "main.py" ],
      cwd: fixture_dir("fastapi-app")
    )
    assert_serves("fastapi-test", "hello from fastapi")
  end
end
