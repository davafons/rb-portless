# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/astro.test.ts

describe "astro" do
  include UpstreamE2E

  it "serves through the proxy" do
    start_app(
      name: "astro-test",
      command: [ "astro", "dev" ],
      cwd: fixture_dir("astro-app")
    )
    assert_serves("astro-test", "hello from astro")
  end
end
