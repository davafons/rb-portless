# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/flask.test.ts

describe "flask" do
  include UpstreamE2E

  it "serves through the proxy" do
    skip "fixture toolchain not installed" unless File.exist?(UpstreamE2E::PYTHON_BIN)

    start_app(
      name: "flask-test",
      command: [ UpstreamE2E::PYTHON_BIN, "app.py" ],
      cwd: fixture_dir("flask-app")
    )
    assert_serves("flask-test", "hello from flask")
  end
end
