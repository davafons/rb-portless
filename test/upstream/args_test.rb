# frozen_string_literal: true

require_relative "../test_helper"

# Mirror of packages/portless/src/args.test.ts
ARGS_SPEC = { "--name" => :value, "--port" => :value, "--force" => :boolean }.freeze
ARGS_CHILD_SPEC = { "--name" => :value, "--force" => :boolean, "--prefix" => :text }.freeze

describe "parseCommandArgs" do
  def parse(*args) = Portless::Args.parse_command_args(*args)

  it "reads a value flag with = and with a separate token" do
    assert_equal "api", parse("deploy", [ "--name=api" ], ARGS_SPEC).value("--name")
    assert_equal "api", parse("deploy", %w[--name api], ARGS_SPEC).value("--name")
    assert_equal "3000", parse("deploy", [ "--port=3000" ], ARGS_SPEC).value("--port")
    assert_equal "3000", parse("deploy", %w[--port 3000], ARGS_SPEC).value("--port")
  end

  it "collects repeated value flags in order" do
    parsed = parse("deploy", [ "--name", "one", "--name", "two", "--name=three" ], ARGS_SPEC)
    assert_equal %w[one two three], parsed.values("--name")
    assert_equal "one", parsed.value("--name")
  end

  it "suggests the known flag for a one edit typo" do
    error = assert_raises(Portless::UsageError) { parse("deploy", %w[--prot 3000], ARGS_SPEC) }
    assert_equal 'Unknown flag "--prot" for rb-portless deploy.', error.message
    assert_includes error.hints, "Did you mean --port?"
  end

  it "rejects a value flag with no value" do
    assert_raises(Portless::UsageError) { parse("deploy", [ "--name" ], ARGS_SPEC) }
    assert_includes assert_raises(Portless::UsageError) { parse("deploy", [ "--name" ], ARGS_SPEC) }.message,
                    "--name requires a value."
    assert_includes assert_raises(Portless::UsageError) { parse("deploy", %w[--name --force], ARGS_SPEC) }.message,
                    "--name requires a value."
  end

  it "rejects a value given to a boolean flag" do
    assert_includes assert_raises(Portless::UsageError) { parse("deploy", [ "--force=1" ], ARGS_SPEC) }.message,
                    "--force does not take a value."
  end

  it "rejects positionals beyond the max" do
    assert_equal %w[a b], parse("deploy", %w[a b], ARGS_SPEC, 2).positionals
    assert_includes assert_raises(Portless::UsageError) { parse("deploy", %w[a b], ARGS_SPEC, 1) }.message,
                    'Unexpected argument "b" for rb-portless deploy.'
  end

  it "turns everything after -- into positionals" do
    parsed = parse("deploy", %w[a -- --force -x], ARGS_SPEC)
    assert_equal %w[a --force -x], parsed.positionals
    refute parsed.has?("--force")
  end
end

describe "visitLeadingFlags" do
  def visit(command, args, spec, &) = Portless::Args.visit_leading_flags(command, args, spec, &)

  it "reports flags in argument order and returns the child command untouched" do
    visits = []
    rest = visit("run", %w[--name=api --force next dev --port 3000], ARGS_CHILD_SPEC) do |flag, value|
      visits << [ flag, value ]
    end
    assert_equal [ [ "--name", "api" ], [ "--force", nil ] ], visits
    assert_equal %w[next dev --port 3000], rest
  end

  it "reports every value in order so a caller can keep the last one" do
    values = []
    visit("run", %w[--name=one --name two], ARGS_CHILD_SPEC) { |_flag, value| values << value unless value.nil? }
    assert_equal %w[one two], values
  end

  it "keeps a value that itself contains =" do
    values = []
    visit("run", %w[--name=a=b next], ARGS_CHILD_SPEC) { |_flag, value| values << value unless value.nil? }
    assert_equal [ "a=b" ], values
  end

  it "accepts an empty text value but not an empty value flag" do
    visits = []
    visit("run", %w[--prefix= --name=x next], ARGS_CHILD_SPEC) { |flag, value| visits << [ flag, value ] }
    assert_equal [ [ "--prefix", "" ], [ "--name", "x" ] ], visits
    error = assert_raises(Portless::UsageError) { visit("run", %w[--name= next], ARGS_CHILD_SPEC) { nil } }
    assert_includes error.message, "--name requires a value."
  end

  it "stops at the first positional so child flags are left alone" do
    visits = []
    rest = visit("run", %w[next --force=false], ARGS_CHILD_SPEC) { |flag| visits << flag }
    assert_empty visits
    assert_equal %w[next --force=false], rest
  end

  it "drops a leading -- and keeps everything after it" do
    visits = []
    rest = visit("run", %w[-- --force next], ARGS_CHILD_SPEC) { |flag| visits << flag }
    assert_empty visits
    assert_equal %w[--force next], rest
  end
end
