# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/nuxt.test.ts

describe "nuxt" do
  include UpstreamE2E

  it "serves through the proxy" do
    start_app(
      name: "nuxt-test",
      command: [ "nuxt", "dev" ],
      cwd: fixture_dir("nuxt-app")
    )
    assert_serves("nuxt-test", "hello from nuxt")
  end
end
