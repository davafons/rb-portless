# frozen_string_literal: true

require_relative "../test_helper"

# Mirror of packages/portless/src/hosts-sync-contract.test.ts
#
# The hosts-sync failure warning is delivered per registering process, so the
# wording on every user-facing surface is pinned here. Upstream's surfaces map
# to ours: README.md, skills/portless -> skills/rb-portless, cli.ts help text ->
# lib/portless/help.rb. rb-portless has no docs site (apps/docs).
describe "hosts-sync failure wording" do
  repo_root = File.expand_path("../..", __dir__)
  surfaces = [ "README.md", "skills/rb-portless/SKILL.md", "lib/portless/help.rb" ]
  hosts_display_hint = "hosts"

  it "%s does not claim the failure warns once" do
    surfaces.each do |surface|
      full = File.join(repo_root, surface)
      assert File.exist?(full), "#{surface} not found; update SURFACES"
      text = File.read(full)
      refute_match(/warns once/i, text, surface)
      refute_match(/cannot write the (hosts )?file, the command/i, text, surface)
    end
  end

  it "%s attributes the warning to the registering command" do
    surfaces.each do |surface|
      text = File.read(File.join(repo_root, surface))
      assert_match(/will not resolve, the command that registered it warns/i, text, surface)
    end
  end

  it "states the warning in every help passage that mentions the opt-out" do
    cli = File.read(File.join(repo_root, "lib/portless/help.rb"))
    passages = cli.split(/\n\s*\n/).select do |block|
      block.include?("PORTLESS_SYNC_HOSTS=0") && block.include?(hosts_display_hint)
    end
    assert_operator passages.length, :>, 0
    passages.each do |passage|
      assert_match(/will not resolve, the command that\s+registered it warns/i, passage)
    end
  end
end
