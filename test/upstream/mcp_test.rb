# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"
require "fileutils"

# Mirror of packages/portless/src/mcp.test.ts

module McpMirror
  ROOT = File.expand_path("../..", __dir__)
  EXE = File.join(ROOT, "exe", "rb-portless")
  CHILD_TOOLS = Portless::Mcp::TOOLS.reject { |t| t["name"] == "tools_profiles" }

  # Commands in `rb-portless --help` that deliberately have no MCP tool.
  OMITTED_COMMANDS = {
    "rb-portless" => "zero-arg and named mode run foreground dev servers",
    "rb-portless run" => "runs a foreground dev server",
    "rb-portless compose up" => "runs Docker Compose, often in the foreground",
    "rb-portless mcp" => "the MCP server itself",
    "rb-portless service install" => "may prompt for sudo",
    "rb-portless trust" => "may prompt for sudo",
    "rb-portless clean" => "may prompt for sudo",
    "rb-portless hosts sync" => "may prompt for sudo",
    "rb-portless hosts clean" => "may prompt for sudo"
  }.freeze

  def call(profiles, method, params = nil)
    message = { "jsonrpc" => "2.0", "id" => 1, "method" => method }
    message["params"] = params unless params.nil?
    Portless::Mcp.create_server(profiles).handle_line(JSON.generate(message))
  end

  # Valid arguments built from a tool's schema: true, 1, ["sample"], or "Sample".
  def sample_args(tool, required_only)
    required = tool["inputSchema"]["required"] || []
    tool["inputSchema"]["properties"].each_with_object({}) do |(key, schema), args|
      next if %w[cwd extraArgs timeoutMs].include?(key)
      next if required_only && !required.include?(key)

      args[key] = { "boolean" => true, "integer" => 1, "array" => [ "sample" ] }.fetch(schema["type"], "Sample")
    end
  end

  def must_raise_mcp(code = -32_602, &block)
    error = _(block).must_raise Portless::Mcp::McpError
    _(error.code).must_equal code
  end

  # Leading command words and flags of a help line or argv, e.g. "alias --remove".
  def command_words(tokens)
    tokens.take_while { |t| t.match?(/\A(--)?[a-z][a-z-]*\z/) }
  end

  def command_of(tool) = command_words(Portless::Mcp.build_argv(tool["name"], sample_args(tool, true)))

  def cli_help(*args)
    out, = Open3.capture2({ "NO_COLOR" => "1" }, RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXE, *args, "--help")
    out.split("\n").map(&:strip)
  end
end

describe "tool registry" do
  include McpMirror

  it "has unique names, each in a non-all profile, and buildArgv covers them" do
    names = Portless::Mcp::TOOLS.map { |t| t["name"] }
    _(names.uniq.size).must_equal names.length
    in_profile = Set.new
    Portless::Mcp::PROFILES.each do |name, p|
      p[:tools].each { |t| in_profile << t } if name != "all" && p[:tools] != :all
    end
    names.each do |name|
      _(in_profile.include?(name)).must_equal true
      Portless::Mcp.build_argv(name, sample_args(Portless::Mcp::TOOLS.find { |t| t["name"] == name }, true)) if name != "tools_profiles"
    end
  end
end

describe "buildArgv" do
  include McpMirror

  it "builds %s argv without cwd or timeoutMs and appends extraArgs last" do
    [
      [ "get", { "name" => "backend", "noWorktree" => true }, [ "get", "backend", "--no-worktree" ] ],
      [ "get", { "name" => "backend", "noWorktree" => false }, [ "get", "backend" ] ],
      [ "get", { "name" => "backend", "json" => true }, [ "get", "backend", "--json" ] ],
      [ "list", { "json" => true }, [ "list", "--json" ] ],
      [ "alias_add", { "name" => "db", "port" => 5432, "force" => true }, [ "alias", "db", "5432", "--force" ] ],
      [
        "alias_add",
        { "name" => "db", "port" => 5432, "upstream" => "https" },
        [ "alias", "db", "5432", "--upstream", "https" ]
      ],
      [
        "alias_add",
        { "name" => "db", "port" => 5432, "upstream" => "https://api.internal:8443", "tld" => [ "test" ] },
        [ "alias", "db", "5432", "--upstream", "https://api.internal:8443", "--tld", "test" ]
      ],
      [
        "alias_add",
        { "name" => "db", "port" => 5432, "upstream" => "http://api.internal" },
        [ "alias", "db", "5432", "--upstream", "http://api.internal" ]
      ],
      [
        "alias_add",
        { "name" => "db", "port" => 5432, "tld" => [ "test", "localhost" ], "force" => true },
        [ "alias", "db", "5432", "--tld", "test", "--tld", "localhost", "--force" ]
      ],
      [ "alias_remove", { "name" => "db" }, [ "alias", "--remove", "db" ] ],
      [ "alias_remove", { "name" => "db", "tld" => [ "test" ] }, [ "alias", "--remove", "db", "--tld", "test" ] ],
      [
        "proxy_start",
        { "port" => 1355, "noTls" => true, "tld" => [ "test", "localhost" ] },
        [ "proxy", "start", "-p", "1355", "--no-tls", "--tld", "test", "--tld", "localhost" ]
      ],
      [ "version", {}, [ "--version" ] ],
      [ "list", { "extraArgs" => [ "--x" ], "cwd" => "/tmp", "timeoutMs" => 5 }, [ "list", "--x" ] ],
      [ "proxy_stop", { "port" => 1356 }, [ "proxy", "stop", "-p", "1356" ] ],
      [ "prune", { "force" => true }, [ "prune", "--force" ] ]
    ].each do |tool, args, argv|
      _(Portless::Mcp.build_argv(tool, args)).must_equal argv
    end
  end

  it "rejects a flag-shaped name so it cannot become a CLI flag" do
    must_raise_mcp { Portless::Mcp.build_argv("alias_add", { "name" => "--remove", "port" => 5432 }) }
  end

  it "rejects an empty tld list with -32602" do
    must_raise_mcp { Portless::Mcp.build_argv("alias_add", { "name" => "db", "port" => 5432, "tld" => [] }) }
  end

  it "rejects upstream %j before launching the CLI" do
    [ nil, 123 ].each do |upstream|
      must_raise_mcp { Portless::Mcp.build_argv("alias_add", { "name" => "db", "port" => 5432, "upstream" => upstream }) }
      res = call([ "core" ], "tools/call", {
                   "name" => "alias_add",
                   "arguments" => { "name" => "db", "port" => 5432, "upstream" => upstream,
                                    "cwd" => "/definitely/not/a/real/dir" }
                 })
      _(res["result"]["isError"]).must_equal true
      _(res["result"]["content"][0]["text"]).must_include "upstream must be a string"
    end
  end

  it "rejects --foreground for proxy start with -32602" do
    must_raise_mcp { Portless::Mcp.build_argv("proxy_start", { "extraArgs" => [ "--foreground" ] }) }
  end
end

describe "profiles" do
  include McpMirror

  it "parses the tools flag" do
    _(Portless::Mcp.parse_tools_flag(" core, ,proxy ")).must_equal [ "core", "proxy" ]
    _(Portless::Mcp.parse_tools_flag("full")).must_equal [ "all" ]
    _(Portless::Mcp.parse_tools_flag("default")).must_equal [ "core" ]
    _(_ { Portless::Mcp.parse_tools_flag("nope") }.must_raise(ArgumentError).message).must_match(/core/)
    _ { Portless::Mcp.parse_tools_flag(" , ") }.must_raise ArgumentError
  end

  it "lists only enabled tools: default excludes proxy, core,proxy includes it" do
    names = ->(p) { call(p, "tools/list")["result"]["tools"].map { |t| t["name"] } }
    core = names.call([ "core" ])
    _(core).must_include "get"
    _(core).wont_include "proxy_start"
    _(names.call([ "core", "proxy" ])).must_include "proxy_start"
    _(names.call([ "all" ]).length).must_equal Portless::Mcp::TOOLS.length
  end

  it "returns an error result for a disabled tool" do
    res = call([ "core" ], "tools/call", { "name" => "proxy_start", "arguments" => {} })
    _(res["error"]).must_be_nil
    _(res["result"]["isError"]).must_equal true
    _(res["result"]["content"][0]["text"]).must_include "not enabled"
  end
end

describe "tools/call validation" do
  include McpMirror

  it "names sorted unknown keys and only the tool's own fields" do
    res = call([ "core" ], "tools/call", {
                 "name" => "get",
                 "arguments" => { "zeta" => 1, "alpha" => 2, "cwd" => "/tmp", "timeoutMs" => 5, "name" => "x" }
               })
    _(res["result"]["isError"]).must_equal true
    _(res["result"]["content"][0]["text"]).must_include "alpha, zeta"
    _(res["result"]["content"][0]["text"]).must_include "Tool arguments: name, noWorktree"
    _(res["result"]["content"][0]["text"]).wont_match(/Unknown argument\(s\)[^.]*cwd/)

    list = call([ "core" ], "tools/call", { "name" => "list", "arguments" => { "bogus" => 1 } })
    _(list["result"]["isError"]).must_equal true
    _(list["result"]["content"][0]["text"]).must_include "Tool arguments: json"
  end

  it "returns -32602 for an unknown tool and -32700 for a non-JSON line" do
    unknown = call([ "core" ], "tools/call", { "name" => "nope", "arguments" => {} })
    _(unknown["error"]["code"]).must_equal(-32_602)

    malformed = Portless::Mcp.create_server([ "core" ]).handle_line("not json")
    _(malformed.key?("id")).must_equal true
    _(malformed["id"]).must_be_nil
    _(malformed["error"]["code"]).must_equal(-32_700)
  end

  it "returns an error result when the child cannot spawn" do
    cwd = "/definitely/not/a/real/dir-portless-mcp"
    res = call([ "core" ], "tools/call", { "name" => "list", "arguments" => { "cwd" => cwd } })
    _(res["result"]["isError"]).must_equal true
    _(res["result"]["content"][0]["text"]).must_include cwd
  end

  it "rejects timeoutMs above the 32-bit maximum" do
    res = call([ "core" ], "tools/call", { "name" => "list", "arguments" => { "timeoutMs" => 2_147_483_648 } })
    _(res["result"]["isError"]).must_equal true
  end
end

describe "initialize and tools/list" do
  include McpMirror

  it "echoes a supported version and falls back to the latest" do
    _(call([ "core" ], "initialize", { "protocolVersion" => "2024-11-05" })["result"]["protocolVersion"])
      .must_equal "2024-11-05"
    res = call([ "core" ], "initialize", { "protocolVersion" => "1999-01-01" })
    _(res["result"]["protocolVersion"]).must_equal "2025-11-25"
    _(res["result"]["serverInfo"]["name"]).must_equal "rb-portless"
    _(res["result"]["capabilities"]).must_equal({ "tools" => {} })
  end

  it "rejects a bad cursor with -32602" do
    [ "abc", "-1", "9999", 3 ].each do |cursor|
      res = call([ "core" ], "tools/list", { "cursor" => cursor })
      _(res["error"]["code"]).must_equal(-32_602)
      _(res["error"]["message"]).must_include "Invalid tools/list cursor"
    end
  end
end

describe "toToolResult" do
  include McpMirror

  it "appends stderr, flags non-zero exit, and fills empty output" do
    ok = Portless::Mcp.to_tool_result(exit_code: 0, stdout: "hi\n", stderr: "")
    _(ok["content"][0]["text"]).must_equal "hi"
    _(ok["isError"]).must_equal false

    bad = Portless::Mcp.to_tool_result(exit_code: 1, stdout: "out", stderr: "boom\n")
    _(bad["content"][0]["text"]).must_equal "out\n\nstderr:\nboom"
    _(bad["isError"]).must_equal true
    _(bad["structuredContent"]["exitCode"]).must_equal 1

    _(Portless::Mcp.to_tool_result(exit_code: 0, stdout: "", stderr: "")["content"][0]["text"]).must_equal "(no output)"
  end
end

describe "CLI coverage" do
  include McpMirror

  it "maps every command in portless --help to a tool or an omission" do
    help = cli_help
    start = help.index("Usage:")
    tools = Set.new(McpMirror::CHILD_TOOLS.map { |t| [ "rb-portless", *command_of(t) ].join(" ") })
    rest = help[(start + 1)..]
    rest.take(rest.index("") || rest.length).each do |line|
      command = [ "rb-portless", *command_words(line.split(/\s+/).drop(1)) ].join(" ")
      assert tools.include?(command) || McpMirror::OMITTED_COMMANDS.key?(command),
             "\"#{command}\" is in --help but has no MCP tool. Add one in mcp.rb or list it as omitted."
    end
  end

  it "types or deliberately rejects every flag a tool's --help lists" do
    pages = {}
    McpMirror::CHILD_TOOLS.each do |tool|
      page, = command_of(tool)
      pages[page] = [ *pages[page], tool ] unless page.start_with?("-")
    end
    pages.each do |page, tools|
      cli_help(page).each do |line|
        words = line.start_with?("rb-portless ") ? command_words(line.split(/\s+/).drop(1)) : []
        owner =
          if line.start_with?("-")
            tools.length == 1 ? tools[0] : nil
          else
            tools.select { |t| command_of(t).each_with_index.all? { |word, i| words[i] == word } }
                 .max_by { |t| command_of(t).length }
          end
        next unless owner

        emitted = Portless::Mcp.build_argv(owner["name"], sample_args(owner, false))
        line.scan(/(?<=^|\s)(-p|--[a-z][a-z-]*)\b/).flatten.each do |flag|
          port_alias = { "-p" => "--port", "--port" => "-p" }[flag]
          next if flag == "--help" || emitted.include?(flag) || (port_alias && emitted.include?(port_alias))

          assert_raises(Portless::Mcp::McpError,
                        "\"#{flag}\" is in \"rb-portless #{page} --help\" but the #{owner['name']} tool does not " \
                        "handle it. Type it in mcp.rb or reject it.") do
            Portless::Mcp.build_argv(owner["name"], sample_args(owner, true).merge("extraArgs" => [ flag ]))
          end
        end
      end
    end
  end
end

describe "portless mcp end to end" do
  include McpMirror

  it "answers over stdio and matches the CLI output" do
    state_dir = Dir.mktmpdir("portless-mcp-")
    env = { "PORTLESS_STATE_DIR" => state_dir, "NO_COLOR" => "1" }
    begin
      cli, = Open3.capture2(env, RbConfig.ruby, "-I", File.join(McpMirror::ROOT, "lib"), McpMirror::EXE, "get", "backend", "--no-worktree")
      expected = cli.strip
      _(expected).wont_equal ""

      lines = [
        { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        {
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: { name: "get", arguments: { name: "backend", noWorktree: true } }
        },
        {
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: { name: "get", arguments: { name: "backend", bogus: 1 } }
        },
        { jsonrpc: "2.0", id: 4, method: "shutdown" }
      ]

      stdout, status = Open3.capture2(env.merge("PORTLESS" => "0"), RbConfig.ruby, "-I", File.join(McpMirror::ROOT, "lib"), McpMirror::EXE,
                                      "mcp", stdin_data: "#{lines.map { |l| JSON.generate(l) }.join("\n")}\n")

      responses = stdout.split("\n").select { |l| !l.strip.empty? }.map { |l| JSON.parse(l) }
      _(responses.map { |r| r["id"] }).must_equal [ 1, 2, 3, 4 ]
      _(responses[1]["result"]["content"][0]["text"]).must_equal expected
      _(responses[2]["error"]).must_be_nil
      _(responses[2]["result"]["isError"]).must_equal true
      _(responses[2]["result"]["content"][0]["text"]).must_include "bogus"
      _(status.exitstatus).must_equal 0
    ensure
      FileUtils.rm_rf(state_dir)
    end
  end
end
