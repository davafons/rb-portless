# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/cli_utils"
require "json"
require "open3"

# Mirror of packages/portless/src/cli-utils.differential.test.ts
#
# Differential test for package-script flag forwarding.
#
# The guard in inject_package_script_framework_flags decides whether appending
# flags to a package script is safe. The shell is the oracle: for each script
# shape below, run what portless would actually run and read the child's argv.
#
#   VIOLATION  portless appended flags and the child never received them
#              (the 502 class: exit 0, framework on its own port).
#   skip       portless declined. Conservative, documented, not a violation.
#
# Add a shape here rather than a bespoke test whenever a new script form comes
# up. Set PORTLESS_DIFFERENTIAL_RUNNERS=bun,npm,pnpm to widen the sweep past bun.
module CliUtilsDifferential
  FRAMEWORK = "vite dev"

  SCRIPTS = {
    # Plain and benign decorations.
    "plain" => FRAMEWORK,
    "withFlags" => "#{FRAMEWORK} --open --strictPort=false",
    "quotedSingle" => "#{FRAMEWORK} --open '/foo&bar'",
    "quotedDouble" => "#{FRAMEWORK} --open \"/foo;bar\"",
    "escapedSpace" => "#{FRAMEWORK} --open /foo\\ bar",
    "glob" => "#{FRAMEWORK} --config ./cfg/*.ts",
    "varExpand" => "#{FRAMEWORK} --mode $NODE_ENV",
    "varBraced" => "#{FRAMEWORK} --mode ${NODE_ENV}",
    "equalsFlag" => "#{FRAMEWORK} --mode=production",
    "tabs" => "#{FRAMEWORK}\t--open",
    "trailingSpace" => "#{FRAMEWORK}   ",
    "leadingSpace" => "   #{FRAMEWORK}",
    "nestedQuotes" => "#{FRAMEWORK} --open \"it's\"",

    # Comments: the class that silently discards the tail.
    "comment" => "#{FRAMEWORK} # note",
    "commentNoSpaceBefore" => "#{FRAMEWORK}# note",
    "commentTight" => "#{FRAMEWORK} #note",
    "commentOnly" => "#{FRAMEWORK} #",
    "multiSpaceComment" => "#{FRAMEWORK}    #    note",
    "hashInWord" => "#{FRAMEWORK} --tag v1#2",
    "hashAfterEscapedSpace" => "#{FRAMEWORK} --open /foo\\ #bar",
    "hashInSingle" => "#{FRAMEWORK} --open '#literal'",
    "hashInDouble" => "#{FRAMEWORK} --open \"#literal\"",
    "hashAfterQuotedEnd" => "#{FRAMEWORK} \"x\" # note",
    "hashAfterRedirect" => "#{FRAMEWORK} > out.log # note",
    "hashAfterTab" => "#{FRAMEWORK}\t# note",
    "escapedHash" => "#{FRAMEWORK} --tag \\#notacomment",
    "hashInSubst" => "#{FRAMEWORK} --define X=$(printf '#hash')",
    "quoteThenHashTight" => "#{FRAMEWORK} --open \"x\"#y",
    "lineContinuationComment" => "#{FRAMEWORK} \\\n# note",
    "twoContinuations" => "#{FRAMEWORK} \\\n --open \\\n# note",
    "commentAfterNewline" => "#{FRAMEWORK}\n# note",
    "semiThenComment" => "#{FRAMEWORK} ;# note",

    # Separators.
    "andand" => "#{FRAMEWORK} && echo done",
    "andandGlued" => "#{FRAMEWORK}&&echo done",
    "oror" => "#{FRAMEWORK} || echo fail",
    "semi" => "#{FRAMEWORK}; echo done",
    "semiGlued" => "#{FRAMEWORK};echo done",
    "pipe" => "#{FRAMEWORK} | tee out.log",
    "background" => "#{FRAMEWORK} &",
    "newline" => "#{FRAMEWORK}\necho done",
    "lineContinuationCmd" => "#{FRAMEWORK} \\\n  --open",

    # Redirections are single commands and must still be injected into.
    "redirect" => "#{FRAMEWORK} > out.log",
    "redirectAppend" => "#{FRAMEWORK} >> out.log",
    "redirectErr" => "#{FRAMEWORK} 2>&1",
    # A bash extension; dash reads the `&` as backgrounding.
    "redirectBoth" => "#{FRAMEWORK} &> out.log",
    "redirectDupToFd" => "#{FRAMEWORK} 2>&1 >out.log",
    "redirectCloseFd" => "#{FRAMEWORK} 2>&-",
    "redirectIn" => "#{FRAMEWORK} < /dev/null",

    # Substitution and grouping.
    "substWordStart" => "$(printf vite) dev",
    "substMidWord" => "#{FRAMEWORK} --define SHA=$(printf abc)",
    "backtickStart" => "`printf vite` dev",
    "subshell" => "(#{FRAMEWORK})",
    "braceGroup" => "{ #{FRAMEWORK}; }",

    # Prefixes and runner wrappers.
    "envPrefix" => "NODE_ENV=production #{FRAMEWORK}",
    "envPrefixTwo" => "A=1 B=2 #{FRAMEWORK}",
    "execPrefix" => "exec #{FRAMEWORK}",
    "bunx" => "bunx vite dev",
    "bunxBun" => "bunx --bun vite dev",
    "npx" => "npx vite dev",
    "pnpmExec" => "pnpm exec vite dev",
    "nestedRun" => "npm run plain",

    # Non-server subcommands and pre-existing flags.
    "build" => "vite build",
    "buildWrapped" => "bunx vite build",
    "modeBuild" => "vite --mode build",
    "hasPort" => "#{FRAMEWORK} --port 5555",
    "hasHost" => "#{FRAMEWORK} --host 0.0.0.0",
    "hasBoth" => "#{FRAMEWORK} --port 5555 --host 0.0.0.0",
    "hasPortEquals" => "#{FRAMEWORK} --port=5555",

    # Other frameworks. The expo shapes carry a second obligation beyond flag
    # forwarding: see the framework-identity test below.
    "expoPlain" => "expo start",
    "expoComment" => "expo start --port 4567 # note",
    "expoAndAnd" => "expo start && echo done",
    "expoRedirect" => "expo start > out.log",
    "expoBuild" => "expo build",
    "expoWrapped" => "bunx expo start",
    "expoExport" => "expo export",
    "expoServe" => "expo serve",

    # Non-server subcommands: the framework CLI rejects the flags, not the shell.
    "optimize" => "vite optimize",
    "optimizeWrapped" => "bunx vite optimize",
    "preview" => "vite preview",
    "bare" => "vite",
    "configValueFirst" => "vite --config ./cfg.ts",
    "modeValueIsServerName" => "vite --mode dev build",
    "modeValueShortFlag" => "vite -m dev optimize",
    "modeValueEquals" => "vite --mode=dev build",

    "dashDash" => "#{FRAMEWORK} -- --extra"
  }.freeze

  SHIMMED_BINARIES = %w[vite expo next].freeze

  # Every shape above that portless declines to inject into. Pinning the set
  # makes the difference reviewable: a fix that widens this list is
  # over-reaching; a fix that narrows it claims new coverage.
  EXPECTED_SKIPS = %w[
    andand
    andandGlued
    background
    backtickStart
    braceGroup
    build
    buildWrapped
    comment
    commentAfterNewline
    commentOnly
    commentTight
    dashDash
    envPrefix
    envPrefixTwo
    execPrefix
    expoAndAnd
    expoBuild
    expoComment
    expoExport
    hasBoth
    hashAfterQuotedEnd
    hashAfterRedirect
    hashAfterTab
    lineContinuationComment
    multiSpaceComment
    modeValueEquals
    modeValueIsServerName
    modeValueShortFlag
    nestedRun
    newline
    optimize
    optimizeWrapped
    oror
    pipe
    redirectBoth
    semi
    semiGlued
    semiThenComment
    subshell
    substWordStart
    twoContinuations
  ].freeze

  module_function

  # Shapes that invoke a package runner by name can't reach the shim on a
  # machine without that runner: an environment limit, excluded from the sweep.
  def required_binary(script)
    first = script.strip.split(/\s+/).first
    %w[bunx npx pnpx bun npm pnpm yarn].include?(first) ? first : nil
  end

  def binary?(name)
    _, status = Open3.capture2e(name, "--version")
    status.success?
  rescue SystemCallError
    false
  end

  # Pick the first runner actually present (CI installs no bun). Windows is a
  # named coverage gap: the shims are `#!/bin/sh`.
  def runners
    requested = ENV["PORTLESS_DIFFERENTIAL_RUNNERS"]&.split(",")&.map(&:strip)&.reject(&:empty?)
    return [] if Portless::Constants::WINDOWS

    (requested || %w[bun pnpm npm].select { |r| binary?(r) }.first(1)).select { |r| binary?(r) }
  end
end

describe "package script forwarding, against the shell" do
  include CliUtilsSupport

  runners = CliUtilsDifferential.runners

  before do
    @dir = Dir.mktmpdir("portless-differential-")
    @capture_path = File.join(@dir, "capture.txt")
    # npx resolves node_modules/.bin before PATH, so the shim lives in both.
    [ File.join(@dir, "bin"), File.join(@dir, "node_modules", ".bin") ].each do |bin_dir|
      FileUtils.mkdir_p(bin_dir)
      CliUtilsDifferential::SHIMMED_BINARIES.each do |name|
        shim = File.join(bin_dir, name)
        File.write(shim, "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$PORTLESS_CAPTURE\"\n")
        File.chmod(0o755, shim)
      end
    end
    File.write(File.join(@dir, "package.json"),
               JSON.generate(name: "portless-differential-fixture", scripts: CliUtilsDifferential::SCRIPTS))
  end

  after { FileUtils.rm_rf(@dir) }

  def run_script(runner, name, extra)
    FileUtils.rm_f(@capture_path)
    # Mirror portless's own convention: npm needs `--` before script arguments.
    forwarded = runner == "npm" && !extra.empty? ? [ "--", *extra ] : extra
    env = {
      "PATH" => "#{File.join(@dir, 'bin')}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}",
      "PORTLESS_CAPTURE" => @capture_path
    }
    _, status = Open3.capture2e(env, runner, "run", name, *forwarded, chdir: @dir)
    delivered = File.exist?(@capture_path) ? File.read(@capture_path).strip : nil
    { status: status.exitstatus, delivered: delivered }
  end

  # Which framework runs and whether portless may append to the script are
  # different questions, and the Expo LAN carve-out only needs the first.
  it "identifies the framework even in shapes it declines to touch" do
    expo_shapes = CliUtilsDifferential::SCRIPTS.keys.select { |n| n.start_with?("expo") }
    # Every expo shape whose first token is literally `expo`, or a runner
    # wrapper portless understands, must resolve regardless of skip status.
    resolved = expo_shapes.to_h { |n| [ n, resolve_framework_basename([ "bun", "run", n ], @dir) ] }
    assert_equal(
      {
        "expoPlain" => "expo",
        "expoComment" => "expo",
        "expoAndAnd" => "expo",
        "expoRedirect" => "expo",
        "expoBuild" => "expo",
        "expoExport" => "expo",
        "expoServe" => "expo",
        "expoWrapped" => "expo"
      },
      resolved
    )
  end

  it "declines exactly the documented set of script shapes" do
    skipped = CliUtilsDifferential::SCRIPTS.keys.select do |name|
      args = [ "bun", "run", name ]
      inject_package_script_framework_flags(args, 4567, @dir)
      args.length == 3
    end
    assert_equal CliUtilsDifferential::EXPECTED_SKIPS.sort, skipped.sort
  end

  it "names the platforms where the shell sweep did not run" do
    skip "the shell sweep ran" unless runners.empty?
    # A skipped sweep is reported, never mistaken for a pass.
    assert_equal true, Portless::Constants::WINDOWS || !CliUtilsDifferential.binary?("bun")
  end

  runners.each do |runner|
    it "never appends flags the #{runner} child does not receive" do
      violations = []
      unmeasured = []

      CliUtilsDifferential::SCRIPTS.each do |name, script|
        needs = CliUtilsDifferential.required_binary(script)
        next if needs && !CliUtilsDifferential.binary?(needs)

        args = [ runner, "run", name ]
        inject_package_script_framework_flags(args, 4567, @dir)
        injected = args[3..].reject { |arg| arg == "--" }
        next if injected.empty?

        result = run_script(runner, name, injected)
        if result[:delivered].nil?
          # The shim never ran: a resolution problem in the fixture, not a
          # verdict about the guard. Named rather than counted as a pass.
          unmeasured << "#{name}: #{script.to_json} (exit #{result[:status]})"
          next
        end
        missing = injected.reject { |flag| result[:delivered].include?(flag) }
        next if missing.empty?

        violations << "#{name}: #{script.to_json}\n    appended #{injected.to_json}\n    " \
                      "child got #{result[:delivered].to_json}"
      end

      assert_equal [], unmeasured, "shim never ran for:\n  #{unmeasured.join("\n  ")}"
      assert_equal [], violations, "portless appended flags the shell discarded:\n  #{violations.join("\n  ")}"
    end
  end
end
