# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/angular.test.ts

describe "angular" do
  include UpstreamE2E

  it "serves through the proxy" do
    start_app(
      name: "angular-test",
      command: [ "ng", "serve", "--project", "app" ],
      cwd: fixture_dir("angular-app")
    )
    assert_serves("angular-test", "<app-root>")
  end
end
