# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "fileutils"

# Port of portless's mcp.test.ts, plus a differential check against the
# built upstream CLI when it is available.
class McpTest < Minitest::Test
  Mcp = Portless::Mcp
  ROOT = File.expand_path("..", __dir__)
  EXE = File.join(ROOT, "exe", "rb-portless")
  CHILD_TOOLS = Mcp::TOOLS.reject { |t| t["name"] == "tools_profiles" }

  def call(profiles, method, params = nil)
    message = { "jsonrpc" => "2.0", "id" => 1, "method" => method }
    message["params"] = params unless params.nil?
    Mcp.create_server(profiles).handle_line(JSON.generate(message))
  end

  # Valid arguments built from a tool's schema: true, 1, ["sample"], or "Sample".
  def sample_args(tool, required_only)
    required = tool["inputSchema"]["required"] || []
    tool["inputSchema"]["properties"].each_with_object({}) do |(key, schema), args|
      next if Mcp::SHARED_FIELDS.include?(key)
      next if required_only && !required.include?(key)

      args[key] = { "boolean" => true, "integer" => 1, "array" => [ "sample" ] }.fetch(schema["type"], "Sample")
    end
  end

  def tool_def(name) = Mcp::TOOLS.find { |t| t["name"] == name }

  def assert_mcp_error(code = -32_602, &block)
    error = assert_raises(Mcp::McpError, &block)
    assert_equal code, error.code
  end

  # ── tool registry ─────────────────────────────────────────────────────

  def test_registry_unique_names_in_profiles_and_buildable
    names = Mcp::TOOLS.map { |t| t["name"] }
    assert_equal names.uniq.length, names.length
    in_profile = Mcp::PROFILES.reject { |n, p| n == "all" || p[:tools] == :all }.values.flat_map { |p| p[:tools] }
    names.each do |name|
      assert_includes in_profile, name
      Mcp.build_argv(name, sample_args(tool_def(name), true)) unless name == "tools_profiles"
    end
  end

  # ── buildArgv ─────────────────────────────────────────────────────────

  BUILD_CASES = [
    [ "get", { "name" => "backend", "noWorktree" => true }, %w[get backend --no-worktree] ],
    [ "get", { "name" => "backend", "noWorktree" => false }, %w[get backend] ],
    [ "get", { "name" => "backend", "json" => true }, %w[get backend --json] ],
    [ "list", { "json" => true }, %w[list --json] ],
    [ "alias_add", { "name" => "db", "port" => 5432, "force" => true }, %w[alias db 5432 --force] ],
    [ "alias_add", { "name" => "db", "port" => 5432, "upstream" => "https" }, %w[alias db 5432 --upstream https] ],
    [ "alias_add", { "name" => "db", "port" => 5432, "upstream" => "https://api.internal:8443", "tld" => [ "test" ] },
      %w[alias db 5432 --upstream https://api.internal:8443 --tld test] ],
    [ "alias_add", { "name" => "db", "port" => 5432, "upstream" => "http://api.internal" },
      %w[alias db 5432 --upstream http://api.internal] ],
    [ "alias_add", { "name" => "db", "port" => 5432, "tld" => %w[test localhost], "force" => true },
      %w[alias db 5432 --tld test --tld localhost --force] ],
    [ "alias_remove", { "name" => "db" }, %w[alias --remove db] ],
    [ "alias_remove", { "name" => "db", "tld" => [ "test" ] }, %w[alias --remove db --tld test] ],
    [ "proxy_start", { "port" => 1355, "noTls" => true, "tld" => %w[test localhost] },
      %w[proxy start -p 1355 --no-tls --tld test --tld localhost] ],
    [ "version", {}, [ "--version" ] ],
    [ "list", { "extraArgs" => [ "--x" ], "cwd" => "/tmp", "timeoutMs" => 5 }, %w[list --x] ],
    [ "proxy_stop", { "port" => 1356 }, %w[proxy stop -p 1356] ],
    [ "prune", { "force" => true }, %w[prune --force] ]
  ].freeze

  def test_build_argv_cases
    BUILD_CASES.each do |tool, args, argv|
      assert_equal argv, Mcp.build_argv(tool, args), "#{tool} #{args}"
    end
  end

  def test_rejects_flag_shaped_name
    assert_mcp_error { Mcp.build_argv("alias_add", { "name" => "--remove", "port" => 5432 }) }
  end

  def test_rejects_empty_tld_list
    assert_mcp_error { Mcp.build_argv("alias_add", { "name" => "db", "port" => 5432, "tld" => [] }) }
  end

  def test_rejects_bad_upstream_before_launching_cli
    [ nil, 123 ].each do |upstream|
      assert_mcp_error { Mcp.build_argv("alias_add", { "name" => "db", "port" => 5432, "upstream" => upstream }) }
      res = call([ "core" ], "tools/call", {
        "name" => "alias_add",
        "arguments" => { "name" => "db", "port" => 5432, "upstream" => upstream, "cwd" => "/definitely/not/a/real/dir" }
      })
      assert res["result"]["isError"]
      assert_includes res["result"]["content"][0]["text"], "upstream must be a string"
    end
  end

  def test_rejects_foreground_for_proxy_start
    assert_mcp_error { Mcp.build_argv("proxy_start", { "extraArgs" => [ "--foreground" ] }) }
  end

  # ── profiles ──────────────────────────────────────────────────────────

  def test_parse_tools_flag
    assert_equal %w[core proxy], Mcp.parse_tools_flag(" core, ,proxy ")
    assert_equal [ "all" ], Mcp.parse_tools_flag("full")
    assert_equal [ "core" ], Mcp.parse_tools_flag("default")
    assert_match(/core/, assert_raises(ArgumentError) { Mcp.parse_tools_flag("nope") }.message)
    assert_raises(ArgumentError) { Mcp.parse_tools_flag(" , ") }
  end

  def test_lists_only_enabled_tools
    names = ->(p) { call(p, "tools/list")["result"]["tools"].map { |t| t["name"] } }
    core = names.call([ "core" ])
    assert_includes core, "get"
    refute_includes core, "proxy_start"
    assert_includes names.call(%w[core proxy]), "proxy_start"
    assert_equal Mcp::TOOLS.length, names.call([ "all" ]).length
  end

  def test_disabled_tool_is_an_error_result
    res = call([ "core" ], "tools/call", { "name" => "proxy_start", "arguments" => {} })
    assert_nil res["error"]
    assert res["result"]["isError"]
    assert_includes res["result"]["content"][0]["text"], "not enabled"
  end

  # ── tools/call validation ─────────────────────────────────────────────

  def test_unknown_keys_sorted_and_own_fields_only
    res = call([ "core" ], "tools/call", {
      "name" => "get", "arguments" => { "zeta" => 1, "alpha" => 2, "cwd" => "/tmp", "timeoutMs" => 5, "name" => "x" }
    })
    text = res["result"]["content"][0]["text"]
    assert res["result"]["isError"]
    assert_includes text, "alpha, zeta"
    assert_includes text, "Tool arguments: name, noWorktree"
    refute_match(/Unknown argument\(s\)[^.]*cwd/, text)

    list = call([ "core" ], "tools/call", { "name" => "list", "arguments" => { "bogus" => 1 } })
    assert list["result"]["isError"]
    assert_includes list["result"]["content"][0]["text"], "Tool arguments: json"
  end

  def test_unknown_tool_and_parse_error
    assert_equal(-32_602, call([ "core" ], "tools/call", { "name" => "nope", "arguments" => {} })["error"]["code"])
    malformed = Mcp.create_server([ "core" ]).handle_line("not json")
    assert malformed.key?("id")
    assert_nil malformed["id"]
    assert_equal(-32_700, malformed["error"]["code"])
  end

  def test_spawn_failure_is_an_error_result
    cwd = "/definitely/not/a/real/dir-portless-mcp"
    res = call([ "core" ], "tools/call", { "name" => "list", "arguments" => { "cwd" => cwd } })
    assert res["result"]["isError"]
    assert_includes res["result"]["content"][0]["text"], cwd
  end

  def test_rejects_timeout_above_int32
    res = call([ "core" ], "tools/call", { "name" => "list", "arguments" => { "timeoutMs" => 2_147_483_648 } })
    assert res["result"]["isError"]
  end

  # ── initialize and tools/list ─────────────────────────────────────────

  def test_initialize_version_negotiation
    assert_equal "2024-11-05", call([ "core" ], "initialize", { "protocolVersion" => "2024-11-05" })["result"]["protocolVersion"]
    res = call([ "core" ], "initialize", { "protocolVersion" => "1999-01-01" })["result"]
    assert_equal "2025-11-25", res["protocolVersion"]
    assert_equal "rb-portless", res["serverInfo"]["name"]
    assert_equal({ "tools" => {} }, res["capabilities"])
  end

  def test_rejects_bad_cursor
    [ "abc", "-1", "9999", 3 ].each do |cursor|
      res = call([ "core" ], "tools/list", { "cursor" => cursor })
      assert_equal(-32_602, res["error"]["code"])
      assert_includes res["error"]["message"], "Invalid tools/list cursor"
    end
  end

  # ── toToolResult ──────────────────────────────────────────────────────

  def test_to_tool_result
    ok = Mcp.to_tool_result(exit_code: 0, stdout: "hi\n", stderr: "")
    assert_equal "hi", ok["content"][0]["text"]
    refute ok["isError"]

    bad = Mcp.to_tool_result(exit_code: 1, stdout: "out", stderr: "boom\n")
    assert_equal "out\n\nstderr:\nboom", bad["content"][0]["text"]
    assert bad["isError"]
    assert_equal 1, bad["structuredContent"]["exitCode"]

    assert_equal "(no output)", Mcp.to_tool_result(exit_code: 0, stdout: "", stderr: "")["content"][0]["text"]
  end

  # ── CLI coverage ──────────────────────────────────────────────────────

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

  # Leading command words and flags of a help line or argv, e.g. "alias --remove".
  def command_words(tokens)
    tokens.take_while { |t| t.match?(/\A(--)?[a-z][a-z-]*\z/) }
  end

  def command_of(tool) = command_words(Mcp.build_argv(tool["name"], sample_args(tool, true)))

  def cli_help(*args)
    env = { "NO_COLOR" => "1" }
    out, = Open3.capture2(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXE, *args, "--help")
    out.split("\n").map(&:strip)
  end

  def test_every_help_command_has_tool_or_omission
    help = cli_help
    start = help.index("Usage:")
    tools = CHILD_TOOLS.map { |t| [ "rb-portless", *command_of(t) ].join(" ") }
    rest = help[(start + 1)..]
    rest.take(rest.index("") || rest.length).each do |line|
      command = [ "rb-portless", *command_words(line.split(/\s+/).drop(1)) ].join(" ")
      assert tools.include?(command) || OMITTED_COMMANDS.key?(command),
             "\"#{command}\" is in --help but has no MCP tool. Add one in mcp.rb or list it as omitted."
    end
  end

  def test_every_help_flag_is_typed_or_rejected
    pages = Hash.new { |h, k| h[k] = [] }
    CHILD_TOOLS.each do |tool|
      page = command_of(tool).first
      pages[page] << tool unless page.start_with?("-")
    end
    pages.each do |page, tools|
      cli_help(page).each do |line|
        words = line.start_with?("rb-portless ") ? command_words(line.split(/\s+/).drop(1)) : []
        owner =
          if line.start_with?("-")
            tools.length == 1 ? tools[0] : nil
          else
            tools.select { |t| command_of(t).each_with_index.all? { |w, i| words[i] == w } }
                 .max_by { |t| command_of(t).length }
          end
        next unless owner

        emitted = Mcp.build_argv(owner["name"], sample_args(owner, false))
        line.scan(/(?<=^|\s)(-p|--[a-z][a-z-]*)\b/).flatten.each do |flag|
          port_alias = { "-p" => "--port", "--port" => "-p" }[flag]
          next if flag == "--help" || emitted.include?(flag) || (port_alias && emitted.include?(port_alias))

          assert_raises(Mcp::McpError,
                        "\"#{flag}\" is in \"rb-portless #{page} --help\" but the #{owner['name']} tool does not handle it.") do
            Mcp.build_argv(owner["name"], sample_args(owner, true).merge("extraArgs" => [ flag ]))
          end
        end
      end
    end
  end

  # ── end to end ────────────────────────────────────────────────────────

  def test_stdio_end_to_end_matches_cli_output
    Dir.mktmpdir("rb-portless-mcp-") do |state_dir|
      env = { "PORTLESS_STATE_DIR" => state_dir, "NO_COLOR" => "1" }
      expected, = Open3.capture2(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXE, "get", "backend", "--no-worktree")
      refute_empty expected.strip

      lines = [
        { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get", arguments: { name: "backend", noWorktree: true } } },
        { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "get", arguments: { name: "backend", bogus: 1 } } },
        { jsonrpc: "2.0", id: 4, method: "shutdown" }
      ]
      out, status = Open3.capture2(env.merge("PORTLESS" => "0"), RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXE, "mcp",
                                   stdin_data: lines.map { |l| JSON.generate(l) }.join("\n") + "\n")
      responses = out.lines.reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
      assert_equal [ 1, 2, 3, 4 ], responses.map { |r| r["id"] }
      assert_equal expected.strip, responses[1]["result"]["content"][0]["text"]
      assert_nil responses[2]["error"]
      assert responses[2]["result"]["isError"]
      assert_includes responses[2]["result"]["content"][0]["text"], "bogus"
      assert_equal 0, status.exitstatus
    end
  end

  def test_usage_errors_exit_2
    _, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXE, "mcp", "--bogus")
    assert_equal 2, status.exitstatus
    assert_includes err, "Unknown argument: --bogus"
    assert_includes err, Mcp::USAGE
  end

  # ── differential: upstream portless vs rb-portless ────────────────────

  UPSTREAM_CLI = ENV.fetch("PORTLESS_UPSTREAM_CLI") do
    [ File.join(ROOT, "references/portless/packages/portless/dist/cli.js"),
      File.expand_path("../rb-portless/references/portless/packages/portless/dist/cli.js", ROOT) ].find { |p| File.exist?(p) }
  end

  DIFF_REQUESTS = [
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/list" },
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "tools_profiles" } },
    { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "get", arguments: { zeta: 1, name: "x" } } },
    { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "alias_add", arguments: { name: "-x", port: 1 } } },
    { jsonrpc: "2.0", id: 6, method: "tools/list", params: { cursor: "99" } },
    { jsonrpc: "2.0", id: 7, method: "bogus" }
  ].freeze

  # Upstream's "portless"/"Portless" (but not portless.json) → rb-portless; version masked.
  def normalize(text)
    text.gsub(/(?<![-\w])[Pp]ortless(?![.\w])/, "rb-portless").gsub(/"version":"[^"]*"/, '"version":"X"')
  end

  def test_differential_against_upstream
    skip "upstream portless CLI not built" unless UPSTREAM_CLI && system("node", "--version", out: File::NULL, err: File::NULL)

    input = DIFF_REQUESTS.map { |r| JSON.generate(r) }.join("\n") + "\n"
    env = { "NO_COLOR" => "1", "PORTLESS_STATE_DIR" => ENV["PORTLESS_STATE_DIR"] }
    %w[all core proxy,diagnostics].each do |profiles|
      upstream, = Open3.capture2(env, "node", UPSTREAM_CLI, "mcp", "--tools", profiles, stdin_data: input)
      ours, = Open3.capture2(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXE, "mcp", "--tools", profiles, stdin_data: input)
      refute_empty upstream
      assert_equal normalize(upstream).lines, normalize(ours).lines, "mcp --tools #{profiles}"
    end

    upstream_help, = Open3.capture2(env, "node", UPSTREAM_CLI, "mcp", "--help")
    ours_help, = Open3.capture2(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXE, "mcp", "--help")
    assert_equal normalize(upstream_help), ours_help
  end
end
