# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/remix.test.ts

describe "remix (react-router v7)" do
  include UpstreamE2E

  it "serves through the proxy" do
    start_app(
      name: "remix-test",
      command: [ "react-router", "dev" ],
      cwd: fixture_dir("remix-app")
    )
    assert_serves("remix-test", "__reactRouterContext")
  end
end
