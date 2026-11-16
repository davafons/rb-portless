# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/svelte.test.ts

describe "svelte (sveltekit)" do
  include UpstreamE2E

  it "serves through the proxy" do
    start_app(
      name: "svelte-test",
      command: [ "vite", "dev" ],
      cwd: fixture_dir("svelte-app")
    )
    assert_serves("svelte-test", "hello from svelte")
  end
end
