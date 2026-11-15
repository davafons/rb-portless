# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# Behaviour brought in line with upstream Vercel portless: --force gating,
# port validation, global-flag stripping, named dispatch, worktree prefixes,
# the PORTLESS=0 bypass, and prune returning what it reaped.
class ParityTest < Minitest::Test
  def setup
    @store = Portless::RouteStore.new
    %w[x.localhost y.localhost].each { |h| @store.remove_route(h) }
  end

  # ── #3 / #8 port validation ──────────────────────────────────────────────

  # ── #5 global flags stripped from anywhere before `--` ───────────────────

  # ── #10 PORTLESS=0|false|skip bypass ─────────────────────────────────────

  # ── #11 worktree branch → prefix ─────────────────────────────────────────

  # ── bare subcommand exits 0; unknown sub-action exits 1 ──────────────────

  private

  # Run the CLI capturing its exit status without killing the test process.
end
