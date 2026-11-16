# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/next.test.ts

describe "next" do
  include UpstreamE2E

  it "serves through the proxy" do
    start_app(
      name: "next-test",
      command: [ "next", "dev" ],
      cwd: fixture_dir("next-app"),
      timeout: 90
    )
    assert_serves("next-test", "hello from next")
  end
end
