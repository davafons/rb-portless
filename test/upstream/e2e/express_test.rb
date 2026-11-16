# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/express.test.ts

describe "express" do
  include UpstreamE2E

  it "serves through the proxy" do
    start_app(
      name: "express-test",
      command: [ "node", "server.js" ],
      cwd: fixture_dir("express-app")
    )
    assert_serves("express-test", "hello from express")
  end
end
