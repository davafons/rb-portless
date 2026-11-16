# frozen_string_literal: true

require_relative "../test_helper"

# Mirror of packages/portless/src/commands.test.ts
describe "suggestCommand" do
  it "suggests a unique command one edit away, including adjacent swaps" do
    assert_equal "list", Portless::Commands.suggest_command("lsit")
  end

  it "does not suggest commands for distant or exact matches" do
    assert_nil Portless::Commands.suggest_command("web")
    assert_nil Portless::Commands.suggest_command("list")
  end
end

describe "hasHelpFlag" do
  it "recognizes help anywhere after the command word, including after a separator" do
    assert Portless::Commands.help_flag?(%w[get x --help])
    assert Portless::Commands.help_flag?(%w[get -- --help])
    assert Portless::Commands.help_flag?(%w[get -- -h])
    refute Portless::Commands.help_flag?(%w[--help])
  end
end
