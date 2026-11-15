# frozen_string_literal: true

require_relative "test_helper"

# Ported from portless args.test.ts + commands behaviour.
class ArgsTest < Minitest::Test
  A = Portless::Args
  SPEC = { "--name" => :value, "--port" => :value, "--force" => :boolean }.freeze
  CHILD = { "--name" => :value, "--prefix" => :text, "--force" => :boolean }.freeze

  def test_value_flag_with_equals_and_separate_token
    assert_equal "api", A.parse_command_args("deploy", [ "--name=api" ], SPEC).value("--name")
    assert_equal "api", A.parse_command_args("deploy", %w[--name api], SPEC).value("--name")
    assert_equal "3000", A.parse_command_args("deploy", [ "--port=3000" ], SPEC).value("--port")
  end

  def test_repeated_value_flags_in_order
    parsed = A.parse_command_args("deploy", %w[--name one --name=two --name three], SPEC)
    assert_equal %w[one two three], parsed.values("--name")
    assert_equal "one", parsed.value("--name")
  end

  def test_suggests_flag_one_edit_away
    err = assert_raises(Portless::UsageError) { A.parse_command_args("deploy", %w[--prot 3000], SPEC) }
    assert_equal 'Unknown flag "--prot" for rb-portless deploy.', err.message
    assert_includes err.hints, "Did you mean --port?"
    assert_includes err.hints, "See: rb-portless deploy --help"
  end

  def test_missing_value_and_boolean_with_value
    assert_raises(Portless::UsageError, "--name requires a value.") { A.parse_command_args("d", [ "--name" ], SPEC) }
    err = assert_raises(Portless::UsageError) { A.parse_command_args("d", %w[--name --force], SPEC) }
    assert_equal "--name requires a value.", err.message
    err = assert_raises(Portless::UsageError) { A.parse_command_args("d", [ "--force=1" ], SPEC) }
    assert_equal "--force does not take a value.", err.message
  end

  def test_max_positionals
    assert_equal %w[a b], A.parse_command_args("deploy", %w[a b], SPEC, 2).positionals
    err = assert_raises(Portless::UsageError) { A.parse_command_args("deploy", %w[a b], SPEC, 1) }
    assert_equal 'Unexpected argument "b" for rb-portless deploy.', err.message
  end

  def test_everything_after_double_dash_is_positional
    parsed = A.parse_command_args("deploy", %w[a -- --force -x], SPEC)
    assert_equal %w[a --force -x], parsed.positionals
    refute parsed.has?("--force")
  end

  def test_no_flags_hint
    err = assert_raises(Portless::UsageError) { A.parse_command_args("trust", [ "--x" ], {}, 0) }
    assert_includes err.hints, "This command takes no flags."
  end

  def test_visit_leading_flags_returns_child_command_untouched
    visits = []
    rest = A.visit_leading_flags("run", %w[--force --name api next dev --port 3000], CHILD) { |f, v| visits << [ f, v ] }
    assert_equal [ [ "--force", nil ], [ "--name", "api" ] ], visits
    assert_equal %w[next dev --port 3000], rest
  end

  def test_visit_keeps_values_with_equals_and_empty_text
    values = []
    A.visit_leading_flags("run", [ "--name=a=b", "next" ], CHILD) { |_, v| values << v }
    assert_equal [ "a=b" ], values
    visits = []
    A.visit_leading_flags("run", [ "--prefix=", "--name=x", "next" ], CHILD) { |f, v| visits << [ f, v ] }
    assert_equal [ [ "--prefix", "" ], [ "--name", "x" ] ], visits
    assert_raises(Portless::UsageError) { A.visit_leading_flags("run", [ "--name=", "next" ], CHILD) { nil } }
  end

  def test_visit_stops_at_positional_and_drops_leading_separator
    assert_equal %w[next --force=false], A.visit_leading_flags("run", %w[next --force=false], CHILD) { flunk }
    assert_equal %w[--force next], A.visit_leading_flags("run", %w[-- --force next], CHILD) { flunk }
  end

  def test_closest_match_and_suggest_command
    c = Portless::Commands
    assert_equal "list", c.suggest_command("lst")
    assert_equal "list", c.suggest_command("lsit") # transposition is one edit
    assert_nil c.suggest_command("myapp")
    assert_nil c.closest_match("--x", %w[--a --b]) # ambiguous → none
    assert c.help_flag?(%w[get foo -h])
    refute c.help_flag?(%w[-h])
  end
end
