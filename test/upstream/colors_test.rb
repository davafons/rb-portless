# frozen_string_literal: true

require_relative "../test_helper"

# Mirror of packages/portless/src/colors.test.ts
describe "supportsColor" do
  it "with %j and terminal %s returns %s" do
    [
      [ {}, true, true ],
      [ {}, false, false ],
      [ { "NO_COLOR" => "1" }, true, false ],
      [ { "NO_COLOR" => "1", "FORCE_COLOR" => "1" }, true, false ],
      [ { "NO_COLOR" => "" }, true, true ],
      [ { "NO_COLOR" => "" }, false, false ],
      [ { "FORCE_COLOR" => "1" }, false, true ],
      [ { "FORCE_COLOR" => "true" }, false, true ],
      [ { "FORCE_COLOR" => "0" }, true, false ],
      [ { "FORCE_COLOR" => "false" }, true, false ]
    ].each do |env, tty, expected|
      assert_equal expected, Portless::Colors.supports_color?(env, tty), "#{env} tty=#{tty}"
    end
  end
end

describe "stripColor" do
  it "removes the codes portless adds and keeps other escape sequences" do
    assert_equal "Error: bold", Portless::Colors.strip("\e[31mError:\e[39m \e[1mbold\e[22m")
    assert_equal "\e[32mfrom the app\e[0m", Portless::Colors.strip("\e[32mfrom the app\e[0m")
  end
end
