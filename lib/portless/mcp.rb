# frozen_string_literal: true

require "json"
require "rbconfig"

module Portless
  # Stdio MCP server for rb-portless: a thin translator that runs the
  # rb-portless CLI for each tool call. Port of portless's mcp.ts.
  #
  # Intentionally omitted: run, <name> <cmd>, --name, and zero-arg mode
  # (foreground dev servers with no detached form), compose (runs Docker
  # Compose, often in the foreground), proxy start --foreground
  # (blocks), trust, clean, hosts sync, hosts clean, and service (may prompt for
  # sudo or need a TTY), plus mcp and --help (the server itself and human help).
  module Mcp
    PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
    DEFAULT_TIMEOUT_MS = 120_000
    PAGE_SIZE = 64
    MAX_TIMEOUT_MS = 2_147_483_647

    SHARED_PROPERTIES = {
      "cwd" => {
        "type" => "string",
        "description" =>
          "Working directory for the command (decides the app name and worktree prefix). Defaults to the server's working directory."
      },
      "extraArgs" => {
        "type" => "array",
        "items" => { "type" => "string" },
        "description" => "Arguments appended verbatim after the typed arguments."
      },
      "timeoutMs" => {
        "type" => "integer",
        "minimum" => 1,
        "maximum" => MAX_TIMEOUT_MS,
        "default" => DEFAULT_TIMEOUT_MS,
        "description" => "Timeout in milliseconds."
      }
    }.freeze

    SHARED_FIELDS = SHARED_PROPERTIES.keys.freeze

    # A JSON-RPC error; -32602 from argument validation becomes a tool error result.
    class McpError < StandardError
      attr_reader :code

      def initialize(code, message)
        super(message)
        @code = code
      end
    end

    module_function

    def tool(name, title, description, properties, required, annotations, in_process: false)
      input_schema = {
        "type" => "object",
        "properties" => in_process ? properties.dup : properties.merge(SHARED_PROPERTIES),
        "additionalProperties" => false
      }
      input_schema["required"] = required unless required.empty?
      { "name" => name, "title" => title, "description" => description, "inputSchema" => input_schema,
        "annotations" => annotations }
    end

    def hints(read_only, destructive, idempotent, open_world)
      { "readOnlyHint" => read_only, "destructiveHint" => destructive, "idempotentHint" => idempotent,
        "openWorldHint" => open_world }
    end

    NAME_PROPERTY = { "type" => "string", "description" => "App or alias name." }.freeze
    PORT_PROPERTY = { "type" => "integer", "minimum" => 1, "maximum" => 65_535, "description" => "Port number." }.freeze
    TLD_PROPERTY = {
      "type" => "array",
      "items" => { "type" => "string" },
      "minItems" => 1,
      "description" => "One or more TLDs to serve. Invalid TLDs are usage errors (CLI exit code 2)."
    }.freeze
    ALIAS_TLD_PROPERTY = TLD_PROPERTY.merge(
      "description" => "TLDs must already be configured; omit for all configured TLDs."
    ).freeze
    READ_ONLY = hints(true, false, true, false).freeze

    # Every tool, in tools/list order.
    TOOLS = [
      tool(
        "list",
        "List routes",
        "List active routes with their URLs, ports, PIDs, uptime, and upstream settings.",
        { "json" => { "type" => "boolean", "description" => "Return routes as JSON, including upstream settings." } },
        [],
        READ_ONLY
      ),
      tool(
        "get",
        "Get app URL",
        "Print the URL for an app name, using the same hostname and worktree logic as rb-portless run: PORTLESS_PREFIX, worktree config, and git worktree detection. Worktree config comes from the current directory, including workspace root defaults, not the named app, so cd into a package to use its per-app options; invalid config fails instead of returning a guessed URL. Template labels over 63 characters are shortened with a stable hash suffix. The app does not need to be running.",
        {
          "name" => NAME_PROPERTY,
          "noWorktree" => {
            "type" => "boolean",
            "description" =>
              "Skip worktree config and naming: PORTLESS_PREFIX, portless.json worktree style and template, and git worktree detection, so the URL has no worktree label."
          },
          "json" => { "type" => "boolean", "description" => "Return the name, hostname, and URL as JSON." }
        },
        [ "name" ],
        READ_ONLY
      ),
      tool(
        "alias_add",
        "Add alias",
        "Register a static route for a service rb-portless does not run, such as a database. The optional upstream accepts https, https://<host>[:<port>], or http://<host>[:<port>]. The alias's positional port always dials loopback; an upstream authority overrides Host and supplies HTTPS SNI for DNS hostnames only, without the port. IP addresses are not sent as SNI. Upstream TLS supports HTTP/1.1 only and disables certificate verification, so it does not authenticate backend identity, including through an SSH tunnel, and does not change client-facing proxy TLS. Restart the proxy daemon after upgrading. Registers it for every configured TLD unless tld selects specific ones. A state directory that another user owns or can write to is refused.",
        {
          "name" => NAME_PROPERTY,
          "port" => PORT_PROPERTY,
          "upstream" => {
            "type" => "string",
            "description" =>
              'Use "https" for loopback TLS without changing Host, "https://<host>[:<port>]" for TLS with Host override and SNI set to a DNS hostname without its port (IP addresses are not sent as SNI), or "http://<host>[:<port>]" for cleartext with Host override. Host uses the full supplied authority, including its optional port. The authority accepts only a hostname or IP address with an optional port, without credentials, path, query, fragment, or whitespace.'
          },
          "tld" => ALIAS_TLD_PROPERTY,
          "force" => {
            "type" => "boolean",
            "description" =>
              "Stop a conflicting app, if any, and replace its route; replacing a static alias stops nothing, and the stopped app's routes on other TLDs can also disappear."
          }
        },
        %w[name port],
        hints(false, true, false, false)
      ),
      tool(
        "alias_remove",
        "Remove alias",
        "Remove a static route registered with alias add. Removes only routes with PID 0, including detached Compose routes; process-owned routes are preserved. Removes it from every configured TLD unless tld selects specific ones.",
        { "name" => NAME_PROPERTY, "tld" => ALIAS_TLD_PROPERTY },
        [ "name" ],
        hints(false, true, true, false)
      ),
      tool(
        "tools_profiles",
        "Show tool profiles",
        "Show the active tool profiles and other profiles you can enable.",
        {},
        [],
        READ_ONLY,
        in_process: true
      ),
      tool(
        "proxy_start",
        "Start proxy",
        "Start the shared rb-portless proxy as a background daemon. Without port, HTTPS uses 443 which may need sudo; MCP cannot answer a sudo prompt, so pass unprivileged for a port below 1024 without sudo, or port (for example 1355). HTTPS may show an OS dialog to trust the local CA; pass skipTrust to skip it. The proxy connects to IPv4 and IPv6 loopback in parallel and uses the first successful connection. A backend listening on both families may accept an extra connection that closes without an HTTP request. Connection failures in the proxy log include each loopback address and error code. A state directory that another user owns or can write to is refused.",
        {
          "port" => PORT_PROPERTY,
          "noTls" => { "type" => "boolean", "description" => "Serve plain HTTP instead of HTTPS." },
          "lan" => { "type" => "boolean", "description" => "Expose the proxy on the local network." },
          "tld" => TLD_PROPERTY,
          "wildcard" => {
            "type" => "boolean",
            "description" => "Allow unregistered subdomains to fall back to their parent route."
          },
          "unprivileged" => {
            "type" => "boolean",
            "description" =>
              "Take a port below 1024 without sudo: bind the wildcard address and accept loopback peers only. Serves plain HTTP on port 80 unless HTTPS is requested, and turns off hosts sync."
          },
          "https" => {
            "type" => "boolean",
            "description" => "Serve HTTPS even with unprivileged or PORTLESS_HTTPS=0."
          },
          "skipTrust" => {
            "type" => "boolean",
            "description" => "Do not add the local CA to the system trust store."
          },
          "cert" => { "type" => "string", "description" => "Custom TLS certificate path; requires key." },
          "key" => { "type" => "string", "description" => "Custom TLS private key path; requires cert." },
          "ip" => { "type" => "string", "description" => "LAN IP to pin; use with lan." }
        },
        [],
        hints(false, false, true, true)
      ),
      tool(
        "proxy_stop",
        "Stop proxy",
        "Stop the shared rb-portless proxy. Pass port when the proxy runs on a non-default port. A recorded process that cannot be verified as the proxy is reported and left running, never signaled. A state directory that another user owns or can write to is refused.",
        { "port" => PORT_PROPERTY },
        [],
        hints(false, true, true, false)
      ),
      tool(
        "doctor",
        "Run doctor",
        "Check local rb-portless health, including the proxy, certificates, and routes.",
        { "json" => { "type" => "boolean", "description" => "Return the report as JSON." } },
        [],
        READ_ONLY
      ),
      tool(
        "prune",
        "Prune servers",
        "Remove stale routes and shares, and stop matching recorded process groups. A group keeps its route and shares while any member is still running, even after it closes its port, and the surviving member is recorded for a retry. A group that cannot be verified is reported and kept, never signaled. A port holder that cannot be proven part of the recorded group is reported and kept, never killed. Stop recorded ngrok and cloudflared tunnels only when their executable names match, including on Windows. Windows process groups and unrelated port holders are not killed. Refuses a state directory that another user owns or can write to, and signals nothing.",
        { "force" => { "type" => "boolean", "description" => "Send SIGKILL instead of SIGTERM." } },
        [],
        hints(false, true, true, false)
      ),
      tool("version", "Print version", "Print the rb-portless version.", {}, [], READ_ONLY)
    ].freeze

    # Profile name -> description and tool names. `all` has tools: :all. Aliases are not keys here.
    PROFILES = {
      "core" => {
        description: "Everyday route lookup and static aliases.",
        tools: %w[list get alias_add alias_remove tools_profiles]
      },
      "proxy" => { description: "Start and stop the shared rb-portless proxy.", tools: %w[proxy_start proxy_stop] },
      "diagnostics" => { description: "Health checks, cleanup, and version information.", tools: %w[doctor prune version] },
      "all" => { description: "Every available tool.", tools: :all }
    }.freeze

    PROFILE_ALIASES = { "default" => "core", "full" => "all" }.freeze
    VALID_PROFILES = "core, proxy, diagnostics, all (aliases: default = core, full = all)"
    USAGE = "Usage: rb-portless mcp [--tools <profiles>]"

    # Node's stripVTControlCharacters pattern.
    ANSI_PATTERN = %r{[\u001B\u009B][\[\]()#;?]*(?:(?:(?:(?:;[-a-zA-Z\d/#&.:=?%@~_]+)*|[a-zA-Z\d]+(?:;[-a-zA-Z\d/#&.:=?%@~_]*)*)?\u0007)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-ntqry=><~]))}

    # Parse a --tools value into canonical profile names (aliases resolved).
    def parse_tools_flag(value)
      requested = value.split(",").map(&:strip).reject(&:empty?)
      raise ArgumentError, "No tools profiles given. Valid profiles: #{VALID_PROFILES}." if requested.empty?

      resolved = []
      unknown = []
      requested.each do |name|
        canonical = PROFILE_ALIASES.fetch(name, name)
        next unknown << name unless PROFILES.key?(canonical)

        resolved << canonical unless resolved.include?(canonical)
      end
      raise ArgumentError, "Unknown tools profile: #{unknown.join(', ')}. Valid profiles: #{VALID_PROFILES}." if unknown.any?

      resolved
    end

    def fail!(message) = raise(McpError.new(-32_602, message))

    # JS Number.isInteger: an integral JSON number, including 5.0.
    def integer_value(value)
      return value if value.is_a?(Integer)
      return value.to_i if value.is_a?(Float) && value.finite? && value == value.floor

      nil
    end

    def read_string(args, key, required)
      value = args[key]
      if value.nil?
        fail!("#{key} is required") if required
        return nil
      end
      fail!("#{key} must be a string") unless value.is_a?(String)
      value
    end

    def read_required_name(args, key)
      value = read_string(args, key, true)
      fail!("#{key} must not be empty") if value.empty?
      fail!("#{key} must not start with \"-\"") if value.start_with?("-")
      value
    end

    def read_boolean(args, key)
      value = args[key]
      return nil if value.nil?

      fail!("#{key} must be a boolean") unless [ true, false ].include?(value)
      value
    end

    def read_port(args, key, required)
      value = args[key]
      if value.nil?
        fail!("#{key} is required") if required
        return nil
      end
      port = integer_value(value)
      fail!("#{key} must be an integer between 1 and 65535") if port.nil? || port < 1 || port > 65_535
      port
    end

    def read_string_array(args, key)
      value = args[key]
      return [] if value.nil?
      if !value.is_a?(Array) || (key == "tld" && value.empty?)
        fail!(key == "tld" ? "tld must not be empty" : "extraArgs must be an array")
      end
      value.each_with_index.map do |item, index|
        fail!("#{key}[#{index}] must be a string") unless item.is_a?(String)
        item
      end
    end

    def validate_shared(args)
      cwd = read_string(args, "cwd", false)
      fail!("cwd must not be empty") if cwd && cwd.empty?
      extra_args = read_string_array(args, "extraArgs")
      timeout = args["timeoutMs"]
      unless timeout.nil?
        ms = integer_value(timeout)
        fail!("timeoutMs must be a positive integer up to 2147483647") if ms.nil? || ms < 1 || ms > MAX_TIMEOUT_MS
      end
      extra_args
    end

    # Build the CLI argv (without ruby/script path, without cwd/timeoutMs) for a child-run tool.
    def build_argv(tool_name, args)
      extra_args = validate_shared(args)
      argv = []

      case tool_name
      when "list"
        argv << "list"
        argv << "--json" if read_boolean(args, "json") == true
      when "get"
        argv.push("get", read_required_name(args, "name"))
        argv << "--no-worktree" if read_boolean(args, "noWorktree") == true
        argv << "--json" if read_boolean(args, "json") == true
      when "alias_add"
        name = read_required_name(args, "name")
        port = read_port(args, "port", true)
        fail!("upstream must be a string") if args.key?("upstream") && args["upstream"].nil?
        upstream = read_string(args, "upstream", false)
        argv.push("alias", name, port.to_s)
        argv.push("--upstream", upstream) if upstream
        read_string_array(args, "tld").each { |tld| argv.push("--tld", tld) }
        argv << "--force" if read_boolean(args, "force") == true
      when "alias_remove"
        argv.push("alias", "--remove", read_required_name(args, "name"))
        read_string_array(args, "tld").each { |tld| argv.push("--tld", tld) }
      when "tools_profiles"
        nil
      when "proxy_start"
        port = read_port(args, "port", false)
        if extra_args.include?("--foreground")
          fail!("extraArgs must not include --foreground because the foreground proxy would block the call")
        end
        argv.push("proxy", "start")
        argv.push("-p", port.to_s) if port
        argv << "--no-tls" if read_boolean(args, "noTls") == true
        argv << "--lan" if read_boolean(args, "lan") == true
        read_string_array(args, "tld").each { |tld| argv.push("--tld", tld) }
        argv << "--wildcard" if read_boolean(args, "wildcard") == true
        argv << "--unprivileged" if read_boolean(args, "unprivileged") == true
        argv << "--https" if read_boolean(args, "https") == true
        argv << "--skip-trust" if read_boolean(args, "skipTrust") == true
        %w[cert key ip].each do |flag|
          value = read_string(args, flag, false)
          argv.push("--#{flag}", value) if value
        end
      when "proxy_stop"
        port = read_port(args, "port", false)
        argv.push("proxy", "stop")
        argv.push("-p", port.to_s) if port
      when "doctor"
        argv << "doctor"
        argv << "--json" if read_boolean(args, "json") == true
      when "prune"
        argv << "prune"
        argv << "--force" if read_boolean(args, "force") == true
      when "version"
        argv << "--version"
      else
        fail!("Unknown tool: #{tool_name}")
      end

      argv.concat(extra_args)
    end

    def to_tool_result(run)
      stdout = run[:stdout].strip
      stderr = run[:stderr].strip
      text = stdout
      text = text.empty? ? "stderr:\n#{stderr}" : "#{text}\n\nstderr:\n#{stderr}" unless stderr.empty?
      text = "(no output)" if text.empty?
      {
        "content" => [ { "type" => "text", "text" => text } ],
        "structuredContent" => { "exitCode" => run[:exit_code], "stdout" => run[:stdout], "stderr" => run[:stderr] },
        "isError" => run[:exit_code] != 0
      }
    end

    # How to re-run this CLI: `ruby -I <lib> <exe>` (upstream: execPath + entry script).
    def cli_argv
      lib_dir = File.expand_path("..", __dir__)
      [ RbConfig.ruby, "-I", lib_dir, File.expand_path("../../exe/rb-portless", __dir__) ]
    end

    def strip_vt(text) = text.dup.force_encoding(Encoding::UTF_8).scrub.gsub(ANSI_PATTERN, "")

    # => { exit_code:, stdout:, stderr: } or { spawn_error: }
    def run_child(argv, cwd, timeout_ms)
      env = { "NO_COLOR" => "1", "FORCE_COLOR" => nil, "PORTLESS" => nil }
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      begin
        pid = Process.spawn(env, *cli_argv, *argv, chdir: cwd, in: File::NULL, out: out_w, err: err_w, pgroup: true)
      rescue SystemCallError => e
        [ out_r, out_w, err_r, err_w ].each(&:close)
        return { spawn_error: e.message }
      end
      out_w.close
      err_w.close
      readers = [ out_r, err_r ].map { |io| Thread.new { io.read.to_s.tap { io.close } } }
      waiter = Process.detach(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (timeout_ms / 1000.0)
      remaining = -> { [ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max }

      # Like Node's "close": the process exited and its stdio streams closed.
      if waiter.join(remaining.call) && readers.all? { |t| t.join(remaining.call) }
        status = waiter.value
        return { exit_code: status.exitstatus, stdout: strip_vt(readers[0].value), stderr: strip_vt(readers[1].value) }
      end

      begin
        Process.kill("KILL", -pid)
      rescue SystemCallError
        begin
          Process.kill("KILL", pid)
        rescue SystemCallError
          nil
        end
      end
      partial = readers.map { |t| t.join(0.2) ? t.value : "" }
      note = "rb-portless command timed out after #{timeout_ms}ms"
      stderr = strip_vt(partial[1])
      stderr = stderr.strip.empty? ? note : "#{stderr.rstrip}\n#{note}"
      { exit_code: nil, stdout: strip_vt(partial[0]), stderr: stderr }
    end

    def tool_error_result(message) = { "content" => [ { "type" => "text", "text" => message } ], "isError" => true }

    def error_response(id, code, message) = { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }

    def result_response(id, result) = { "jsonrpc" => "2.0", "id" => id, "result" => result }

    # A server for the given canonical profile names.
    class Server
      attr_reader :profiles

      def initialize(profiles)
        @profiles = profiles
        @shutdown = false
        @enabled = []
        profiles.each do |profile_name|
          profile = PROFILES[profile_name]
          next unless profile

          names = profile[:tools] == :all ? TOOLS.map { |t| t["name"] } : profile[:tools]
          names.each { |n| @enabled << n unless @enabled.include?(n) }
        end
      end

      def shutdown? = @shutdown

      def handle_line(line)
        return nil if line.strip.empty?

        begin
          message = JSON.parse(line)
        rescue JSON::ParserError => e
          return Mcp.error_response(nil, -32_700, "Parse error: #{e.message}")
        end
        return nil unless message.is_a?(Hash)

        handle_request(message)
      end

      private

      def handle_request(message)
        id = message["id"]
        has_id = message.key?("id")
        method = message["method"]
        return has_id ? Mcp.error_response(id, -32_600, "Invalid request: missing method") : nil unless method.is_a?(String)
        return nil unless has_id

        has_params = message.key?("params")
        params = message["params"]

        case method
        when "initialize" then initialize_result(id, has_params, params)
        when "ping" then Mcp.result_response(id, {})
        when "tools/list" then tools_list(id, has_params, params)
        when "tools/call" then tools_call(id, params)
        when "shutdown"
          @shutdown = true
          Mcp.result_response(id, {})
        else
          Mcp.error_response(id, -32_601, "Method not found: #{method}")
        end
      end

      def initialize_result(id, has_params, params)
        return Mcp.error_response(id, -32_602, "params must be an object") if has_params && !params.is_a?(Hash)

        requested = params.is_a?(Hash) ? params["protocolVersion"] : nil
        if params.is_a?(Hash) && params.key?("protocolVersion") && !requested.is_a?(String)
          return Mcp.error_response(id, -32_602, "protocolVersion must be a string")
        end

        version = PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS[0]
        lookup = []
        lookup << "the get tool to find an app's URL" if @enabled.include?("get")
        lookup << "the list tool to see active routes" if @enabled.include?("list")
        instructions = [
          "rb-portless MCP server. Active profiles: #{@profiles.join(', ')}.",
          lookup.empty? ? "" : "Use #{lookup.join(', ')}.",
          "Start dev servers with `rb-portless run <cmd>` in a shell; value flags accept `--flag <value>` or `--flag=<value>`. MCP does not run them.",
          @enabled.include?("tools_profiles") ? "Call the tools_profiles tool to see other tool profiles." : ""
        ].reject(&:empty?).join(" ")
        Mcp.result_response(id, {
          "protocolVersion" => version,
          "capabilities" => { "tools" => {} },
          "serverInfo" => { "name" => "rb-portless", "title" => "rb-portless", "version" => VERSION },
          "instructions" => instructions
        })
      end

      def tools_list(id, has_params, params)
        return Mcp.error_response(id, -32_602, "params must be an object") if has_params && !params.is_a?(Hash)

        cursor = params.is_a?(Hash) ? params["cursor"] : nil
        page = TOOLS.select { |t| @enabled.include?(t["name"]) }
        start = 0
        unless cursor.nil?
          return Mcp.error_response(id, -32_602, "Invalid tools/list cursor") unless cursor.is_a?(String) && cursor.match?(/\A\d+\z/)

          start = cursor.to_i
          return Mcp.error_response(id, -32_602, "Invalid tools/list cursor") if start > page.length
        end
        result = { "tools" => page[start, PAGE_SIZE] || [] }
        result["nextCursor"] = (start + PAGE_SIZE).to_s if start + PAGE_SIZE < page.length
        Mcp.result_response(id, result)
      end

      def tools_call(id, params)
        return Mcp.error_response(id, -32_602, "params must be an object") unless params.is_a?(Hash)
        return Mcp.error_response(id, -32_602, "params.name must be a string") unless params["name"].is_a?(String)

        tool_name = params["name"]
        raw_args = params["arguments"]
        return Mcp.error_response(id, -32_602, "tool arguments must be an object") if !raw_args.nil? && !raw_args.is_a?(Hash)

        args = raw_args || {}
        definition = TOOLS.find { |t| t["name"] == tool_name }
        return Mcp.error_response(id, -32_602, "Unknown tool: #{tool_name}") unless definition
        unless @enabled.include?(tool_name)
          return Mcp.result_response(id, Mcp.tool_error_result(
            "Tool #{tool_name} is not enabled. Restart with rb-portless mcp --tools all or add a profile that includes it."
          ))
        end

        accepted = definition["inputSchema"]["properties"].keys
        unknown = args.keys.reject { |k| accepted.include?(k) }.sort
        unless unknown.empty?
          own = accepted.reject { |k| SHARED_FIELDS.include?(k) }.join(", ")
          own = "none" if own.empty?
          return Mcp.result_response(id, Mcp.tool_error_result(
            "Unknown argument(s) for #{tool_name}: #{unknown.join(', ')}. Tool arguments: #{own}."
          ))
        end

        begin
          return Mcp.result_response(id, tools_profiles_result) if tool_name == "tools_profiles"

          argv = Mcp.build_argv(tool_name, args)
          cwd = args["cwd"].is_a?(String) ? args["cwd"] : Dir.pwd
          timeout_ms = Mcp.integer_value(args["timeoutMs"]) || DEFAULT_TIMEOUT_MS
          run = Mcp.run_child(argv, cwd, timeout_ms)
          if run[:spawn_error]
            return Mcp.result_response(id, Mcp.tool_error_result("Failed to run rb-portless in #{cwd}: #{run[:spawn_error]}"))
          end

          Mcp.result_response(id, Mcp.to_tool_result(run))
        rescue McpError => e
          return Mcp.result_response(id, Mcp.tool_error_result(e.message)) if e.code == -32_602

          Mcp.error_response(id, e.code, e.message)
        rescue StandardError => e
          Mcp.error_response(id, -32_603, "Failed to run rb-portless: #{e.message}")
        end
      end

      def tools_profiles_result
        summaries = PROFILES.map do |name, profile|
          { "name" => name, "description" => profile[:description],
            "toolCount" => profile[:tools] == :all ? TOOLS.length : profile[:tools].length,
            "usage" => "rb-portless mcp --tools #{name}" }
        end
        text = [
          "Active profiles: #{@profiles.join(', ')}",
          *summaries.map { |p| "#{p['name']}: #{p['description']} (#{p['toolCount']} tools), #{p['usage']}" }
        ].join("\n")
        { "content" => [ { "type" => "text", "text" => text } ],
          "structuredContent" => { "activeProfiles" => @profiles, "profiles" => summaries }, "isError" => false }
      end
    end

    def create_server(profiles) = Server.new(profiles)

    def help_text
      [
        USAGE,
        "",
        "Start a Model Context Protocol server over stdio. The client launches this",
        "process and exchanges newline-delimited JSON-RPC messages on stdin/stdout;",
        "stdout carries only protocol messages and diagnostics go to stderr.",
        "",
        "Profiles:",
        *PROFILES.map { |name, profile| "  #{name.ljust(13)}#{profile[:description]}" },
        "",
        "Common tools:",
        "  list            List active routes (json: true for JSON).",
        "  get             Print an app URL (json: true for JSON).",
        "  alias_add       Register a static route with an optional HTTP or HTTPS upstream.",
        "  tools_profiles  Show active and available profiles.",
        "",
        "Worktree options inherit from the workspace root into package directories.",
        "Local values override. Templates must render valid DNS labels; labels over 63 characters are shortened with a stable hash suffix.",
        "",
        "Pass --tools with a comma separated list of profiles. The default is core.",
        "Aliases: default = core, full = all. Use the extraArgs argument on any tool",
        "to append CLI flags that are not typed into the tool schema.",
        "Zero-arg run is CLI-only; Turbo mode exits 2 for forwarded arguments through a root script with shell operators or a comment.",
        "",
        "Environment:",
        "  PORTLESS_STATE_DIR  Directory for rb-portless state.",
        "  PORTLESS_PORT       Default proxy port.",
        "  PORTLESS_TLD        Default TLD or comma separated TLD list.",
        "  PORTLESS_PREFIX     Override the worktree label (empty disables it).",
        "",
        "Client config:",
        '  {"mcpServers":{"rb-portless":{"command":"rb-portless","args":["mcp"]}}}',
        '  {"mcpServers":{"rb-portless":{"command":"rb-portless","args":["mcp","--tools","all"]}}}',
        ""
      ].join("\n")
    end

    def print_help(out = $stdout)
      out.write(help_text)
      0
    end

    # `rb-portless mcp [--tools <profiles>]`. Returns the exit code.
    def run(args, input: $stdin, output: $stdout, error: $stderr)
      usage_error = proc do |message|
        error.puts Colors.red("Error: #{message}", io: error)
        error.puts USAGE
        return 2
      end

      tools_value = nil
      index = 0
      while index < args.length
        arg = args[index]
        return print_help(output) if [ "--help", "-h" ].include?(arg)

        if arg == "--tools"
          usage_error.call("--tools requires a value") if index + 1 >= args.length
          tools_value = args[index + 1]
          index += 2
          next
        end
        if arg.start_with?("--tools=")
          tools_value = arg.delete_prefix("--tools=")
          index += 1
          next
        end
        usage_error.call("Unknown argument: #{arg}")
      end

      profiles =
        begin
          tools_value.nil? ? [ "core" ] : parse_tools_flag(tools_value)
        rescue ArgumentError => e
          usage_error.call(e.message)
        end

      server = create_server(profiles)
      input.each_line do |line|
        response = server.handle_line(line.chomp)
        unless response.nil?
          begin
            output.write("#{JSON.generate(response)}\n")
            output.flush
          rescue IOError, SystemCallError
            break
          end
        end
        break if server.shutdown?
      end
      0
    end
  end
end
