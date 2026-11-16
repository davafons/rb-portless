# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/hono.test.ts

describe "hono" do
  include UpstreamE2E

  it "serves through the proxy" do
    start_app(
      name: "hono-test",
      command: [ "node", "server.js" ],
      cwd: fixture_dir("hono-app")
    )
    assert_serves("hono-test", "hello from hono")
  end
end
