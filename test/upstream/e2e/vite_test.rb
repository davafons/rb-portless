# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/vite.test.ts

describe "vite" do
  include UpstreamE2E

  it "serves through the proxy" do
    start_app(
      name: "vite-test",
      command: [ "vite" ],
      cwd: fixture_dir("vite-app")
    )
    assert_serves("vite-test", "hello from vite")
  end
end
