# frozen_string_literal: true

# Differential check: runs the same CLI/HTTP scenarios against upstream
# portless (node dist/cli.js) and rb-portless, each with its own state dir,
# normalizes the output and reports every difference.
#
#   ruby test/differential/run.rb [--upstream PATH/TO/cli.js] [--port 16xxx] [--only REGEX] [-v]
#
# Safe by construction: plain-HTTP proxies on one high port (the tools run
# one after the other), PORTLESS_SYNC_HOSTS=0, isolated PORTLESS_STATE_DIRs,
# and only --help for anything that touches trust, hosts, services or state.
# Exit status: 0 when no differences, 1 otherwise.

require "open3"
require "json"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"
require "optparse"
require "openssl"

ROOT = File.expand_path("../..", __dir__)

opts = {
  upstream: File.expand_path("../rb-portless/references/portless/packages/portless/dist/cli.js", ROOT),
  port: nil, only: nil, verbose: false, tmp: ENV["PORTLESS_E2E_TMPDIR"] || Dir.tmpdir
}
OptionParser.new do |o|
  o.on("--upstream PATH") { |v| opts[:upstream] = v }
  o.on("--port N", Integer) { |v| opts[:port] = v }
  o.on("--only REGEX") { |v| opts[:only] = Regexp.new(v) }
  o.on("--tmp DIR") { |v| opts[:tmp] = v }
  o.on("-v", "--verbose") { opts[:verbose] = true }
end.parse!
alt = File.expand_path("references/portless/packages/portless/dist/cli.js", ROOT)
opts[:upstream] = alt if !File.exist?(opts[:upstream]) && File.exist?(alt)
abort "upstream CLI not found: #{opts[:upstream]}" unless File.exist?(opts[:upstream])

def free_port
  200.times do
    port = rand(16_000..16_999)
    begin
      TCPServer.new("127.0.0.1", port).close
      return port
    rescue Errno::EADDRINUSE
      next
    end
  end
  raise "no free port"
end

PROXY_PORT = opts[:port] || free_port
DEAD_PORT = free_port # alias target nobody listens on
OTHER_PORT = free_port # a second proxy port, only used in mismatch scenarios

# A live backend that answers with the request it saw (line + headers) as JSON,
# so the proxy's request rewriting (X-Forwarded-*, hops, Host) is compared too.
ECHO = TCPServer.new("127.0.0.1", 0)
ECHO_PORT = ECHO.addr[1]
Thread.new do
  loop do
    client = ECHO.accept
    Thread.new(client) do |c|
      line = c.gets.to_s.strip
      headers = {}
      while (l = c.gets) && l != "\r\n"
        k, v = l.split(":", 2)
        headers[k.strip.downcase] = v.to_s.strip
      end
      body = JSON.generate(line: line, headers: headers.sort.to_h)
      c.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Backend: echo\r\n" \
              "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    ensure
      c.close
    end
  rescue IOError
    break
  end
end

class Tool
  attr_reader :name, :state_dir

  def initialize(name, argv, tmp)
    @name = name
    @argv = argv
    @state_dir = File.realpath(Dir.mktmpdir("diff-#{name}-", tmp))
    @cwd = File.realpath(Dir.mktmpdir("diff-#{name}-cwd-", tmp))
  end

  def env(extra = {})
    {
      "PORTLESS_STATE_DIR" => @state_dir, "PORTLESS_PORT" => PROXY_PORT.to_s, "PORTLESS_HTTPS" => "0",
      "PORTLESS_SYNC_HOSTS" => "0", "NO_COLOR" => "1", "FORCE_COLOR" => nil, "CI" => nil,
      "PORTLESS_LAN" => nil, "PORTLESS_TLD" => nil, "PORTLESS_APP_PORT" => nil
    }.merge(extra)
  end

  def run(args, env: {}, timeout: 30)
    Open3.popen3(self.env(env), *@argv, *args, chdir: @cwd, unsetenv_others: false) do |i, o, e, t|
      i.close
      out = Thread.new { o.read }
      err = Thread.new { e.read }
      unless t.join(timeout)
        Process.kill("KILL", t.pid) rescue nil
        return { "exit" => "TIMEOUT", "stdout" => out.value, "stderr" => err.value }
      end
      { "exit" => t.value.exitstatus, "stdout" => out.value, "stderr" => err.value }
    end
  end

  def write(name, content)
    File.write(File.join(@cwd, name), content)
  end

  def remove(name)
    FileUtils.rm_f(File.join(@cwd, name))
  end

  def cleanup
    FileUtils.rm_rf([ @state_dir, @cwd ])
  end

  def normalize(text)
    s = text.to_s.dup
    [ @state_dir, @state_dir.sub(%r{\A/private}, ""), @cwd, @cwd.sub(%r{\A/private}, "") ].each do |p|
      s.gsub!(p, p.start_with?(@cwd.sub(%r{\A/private}, "")) ? "<CWD>" : "<STATE>")
    end
    s.gsub!(Dir.home, "<HOME>")
    s.gsub!(/(?<![\w-])portless(?![\w])/, "rb-portless")
    s.gsub!(/rb-rb-portless/, "rb-portless")
    s.gsub!(PROXY_PORT.to_s, "<PROXY_PORT>")
    s.gsub!(DEAD_PORT.to_s, "<DEAD_PORT>")
    s.gsub!(ECHO_PORT.to_s, "<ECHO_PORT>")
    s.gsub!(OTHER_PORT.to_s, "<OTHER_PORT>")
    s.gsub!(/\b(Killed process|pid|PID|process group|pgid)\s+\d+/) { "#{Regexp.last_match(1)} <PID>" }
    s.gsub!(/"(pid|registeredAt)":\s*\d+/) { "\"#{Regexp.last_match(1)}\":<N>" }
    s.gsub!(/\bup \d+[smhd]( \d+[smhd])?/, "up <UPTIME>")
    s.gsub!(/\b\d+\.\d+\.\d+(-[\w.]+)?\b/, "<VERSION>")
    s.gsub!(/\d{4}-\d\d-\d\dT[\d:.]+Z/, "<TIME>")
    s.gsub!(/(?<![\d.])4\d{3}(?![\d.])/, "<APP_PORT>") # random 4000-4999 app ports
    s.gsub!(/(Proxy PID file points to the responding proxy process: )\d+/, "\\1<PID>")
    s
  end
end

UPSTREAM = Tool.new("upstream", [ "node", opts[:upstream] ], opts[:tmp])
OURS = Tool.new("rb", [ RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe/rb-portless") ], opts[:tmp])

# --- scenario definitions --------------------------------------------------

HELP = [
  %w[--help], %w[-h], %w[run --help], %w[proxy --help], %w[proxy start --help], %w[proxy stop --help],
  %w[get --help], %w[alias --help], %w[list --help], %w[doctor --help], %w[trust --help], %w[clean --help],
  %w[prune --help], %w[hosts --help], %w[hosts sync --help], %w[hosts clean --help], %w[service --help],
  %w[service install --help], %w[compose --help], %w[mcp --help], %w[myapp --help]
].freeze

USAGE = [
  %w[get], %w[get a b], %w[get --bogus x], %w[list extra], %w[list --bogus], %w[alias], %w[alias foo],
  %w[alias foo notaport], %w[alias foo 0], %w[alias foo 70000], %w[alias --remove], %w[alias --bogus],
  %w[proxy], %w[proxy bogus], %w[proxy start --port abc], %w[proxy start -p 0], %w[proxy start --bogus],
  %w[proxy stop extra], %w[hosts], %w[hosts bogus], %w[service], %w[service bogus], %w[service status extra],
  %w[prune extra], %w[prune --bogus], %w[doctor --bogus], %w[trust extra], %w[clean extra],
  %w[run --app-port abc true], %w[run --app-port], %w[run --name], %w[--name], %w[--script],
  %w[myapp], %w[myapp --app-port 99999 true], %w[run --bogus-flag true], %w[--version extra]
].freeze

STATELESS = [ %w[list], %w[list --json], %w[get myapp], %w[get myapp --json], %w[get myapp --no-worktree],
              %w[prune], %w[proxy stop] ].freeze

def http(method, host, headers: {}, path: "/", version: "HTTP/1.1", tls: false)
  sock = TCPSocket.new("127.0.0.1", PROXY_PORT)
  if tls
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    sock = OpenSSL::SSL::SSLSocket.new(sock, ctx)
    sock.hostname = host if host
    sock.sync_close = true
    sock.connect
  end
  lines = [ "#{method} #{path} #{version}" ]
  lines << "Host: #{host}" if host
  headers.each { |k, v| lines << "#{k}: #{v}" }
  lines << "Connection: close"
  sock.write(lines.join("\r\n") + "\r\n\r\n")
  raw = +""
  begin
    loop { raw << sock.readpartial(65_536) }
  rescue EOFError, OpenSSL::SSL::SSLError, Errno::ECONNRESET
    nil
  end
  sock.close
  head, body = raw.split("\r\n\r\n", 2)
  status_line, *hdrs = head.split("\r\n")
  h = hdrs.map { |l| l.split(":", 2).map(&:strip) }.to_h { |k, v| [ k.downcase, v ] }
  body = dechunk(body) if h["transfer-encoding"] == "chunked"
  %w[date content-length connection keep-alive transfer-encoding].each { |k| h.delete(k) }
  { "status" => status_line.split(" ", 3)[1], "headers" => h.sort.to_h, "body" => body.to_s }
rescue StandardError => e
  { "error" => e.class.name }
end

def dechunk(body)
  out = +""
  rest = body.to_s
  while (m = rest.match(/\A([0-9a-fA-F]+)\r\n/))
    size = m[1].to_i(16)
    break if size.zero?

    out << rest[m.end(0), size]
    rest = rest[(m.end(0) + size + 2)..] || ""
  end
  out
end

HTTP_CASES = {
  "404 json" => [ "GET", "nope.localhost" ],
  "404 html" => [ "GET", "nope.localhost", { "Accept" => "text/html" } ],
  "404 HEAD" => [ "HEAD", "nope.localhost" ],
  "421 json" => [ "GET", "example.com" ],
  "421 html" => [ "GET", "example.com", { "Accept" => "text/html" } ],
  "404 ip host" => [ "GET", "127.0.0.1" ],
  "400 no host" => [ "GET", nil ],
  "502 json" => [ "GET", "dead.localhost" ],
  "502 html" => [ "GET", "dead.localhost", { "Accept" => "text/html" } ],
  "508 json" => [ "GET", "dead.localhost", { "x-portless-hops" => "5" } ],
  "508 html" => [ "GET", "dead.localhost", { "x-portless-hops" => "5", "Accept" => "text/html" } ],
  "wildcard strict 404" => [ "GET", "sub.dead.localhost" ],
  "400 no host http/1.0" => [ "GET", nil, {}, "HTTP/1.0" ],
  "404 HEAD health probe" => [ "HEAD", "localhost" ]
}.freeze

RUN_CASES = {
  "exit code" => [ "myapp", "sh", "-c", "exit 3" ],
  "env" => [ "myapp", "sh", "-c", "echo PORT=$PORT HOST=$HOST URL=$PORTLESS_URL" ],
  "run --name" => [ "run", "--name", "named", "sh", "-c", "echo $PORTLESS_URL" ],
  "--name reserved" => [ "--name", "list", "sh", "-c", "echo $PORTLESS_URL" ],
  "app-port" => [ "myapp", "--app-port", "DEAD", "sh", "-c", "echo PORT=$PORT" ],
  "dotted name" => [ "api.myapp", "sh", "-c", "echo $PORTLESS_URL" ],
  "full hostname" => [ "api.myapp.localhost", "sh", "-c", "echo $PORTLESS_URL" ],
  "run no command, no package.json" => [ "run" ],
  "zero-arg no package.json" => []
}.freeze

# Returns { scenario_name => result_hash } for one tool.
def collect(tool, only)
  results = {}
  record = lambda do |name, &blk|
    next if only && name !~ only

    results[name] = blk.call
  end

  HELP.each { |args| record.call("help: #{args.join(' ')}") { tool.run(args) } }
  USAGE.each { |args| record.call("usage: #{args.join(' ')}") { tool.run(args) } }
  STATELESS.each { |args| record.call("no proxy: #{args.join(' ')}") { tool.run(args) } }
  record.call("no proxy: doctor --json") { tool.run(%w[doctor --json]) }

  started = tool.run(%W[proxy start --no-tls -p #{PROXY_PORT}])
  results["proxy: start --no-tls"] = started
  record.call("proxy: start again (already running)") { tool.run(%W[proxy start --no-tls -p #{PROXY_PORT}]) }
  record.call("proxy: start with tls (mismatch)") { tool.run(%W[proxy start -p #{PROXY_PORT} --skip-trust]) }
  record.call("proxy: start with --wildcard (mismatch)") { tool.run(%W[proxy start --no-tls -p #{PROXY_PORT} --wildcard]) }
  record.call("proxy: start --tld test (mismatch)") { tool.run(%W[proxy start --no-tls -p #{PROXY_PORT} --tld test]) }
  record.call("proxy: alias dead") { tool.run(%W[alias dead #{DEAD_PORT}]) }
  record.call("proxy: alias dead again") { tool.run(%W[alias dead #{DEAD_PORT}]) }
  record.call("proxy: alias other.localhost") { tool.run(%W[alias other.localhost #{DEAD_PORT}]) }
  record.call("proxy: alias echo") { tool.run(%W[alias echo #{ECHO_PORT}]) }
  record.call("proxy: alias up --upstream https") { tool.run(%W[alias up #{DEAD_PORT} --upstream https://example.test]) }
  record.call("proxy: alias Bad_Name") { tool.run(%w[alias Bad_Name 3000]) }
  record.call("proxy: alias --force existing") { tool.run(%W[alias dead #{DEAD_PORT} --force]) }
  record.call("proxy: alias over name with tld test") { tool.run(%W[alias foo.test #{DEAD_PORT}]) }
  record.call("proxy: get bad name") { tool.run(%w[get Bad_Name]) }
  record.call("proxy: get up --json") { tool.run(%w[get up --json]) }
  record.call("proxy: start on other port while running") do
    tool.run(%W[proxy start --no-tls -p #{OTHER_PORT}]).tap { tool.run(%w[proxy stop -p] + [ OTHER_PORT.to_s ]) }
  end
  record.call("proxy: stop -p other port (nothing there)") { tool.run(%W[proxy stop -p #{OTHER_PORT}]) }
  sleep 1.5 # proxies reload routes.json on a debounce
  record.call("proxy: list") { tool.run(%w[list]) }
  record.call("proxy: list --json") { tool.run(%w[list --json]) }
  record.call("proxy: get dead") { tool.run(%w[get dead]) }
  record.call("proxy: get dead --json") { tool.run(%w[get dead --json]) }
  record.call("proxy: get dead.localhost") { tool.run(%w[get dead.localhost]) }
  record.call("proxy: routes.json") do
    { "body" => JSON.pretty_generate(JSON.parse(File.read(File.join(tool.state_dir, "routes.json")))) }
  end
  record.call("http: echo proxied request") do
    http("GET", "echo.localhost", path: "/a/b?c=1", headers: { "X-Forwarded-For" => "1.2.3.4", "User-Agent" => "diff" })
  end
  record.call("http: echo wildcard subdomain (strict)") { http("GET", "sub.echo.localhost") }
  record.call("http: echo with port in Host") { http("GET", "echo.localhost:#{PROXY_PORT}") }
  record.call("http: echo POST body") { http("POST", "echo.localhost", headers: { "Content-Length" => "0" }) }
  HTTP_CASES.each do |name, (m, host, hdrs, version)|
    record.call("http: #{name}") { http(m, host, headers: hdrs || {}, version: version || "HTTP/1.1") }
  end
  RUN_CASES.each do |name, args|
    record.call("run: #{name}") { tool.run(args.map { |a| a == "DEAD" ? DEAD_PORT.to_s : a }, timeout: 20) }
  end
  record.call("run: PORTLESS=0") { tool.run(%w[myapp sh -c] + [ "echo PORT=$PORT" ], env: { "PORTLESS" => "0" }) }
  tool.write("package.json", JSON.generate(name: "pkgapp", scripts: { dev: "echo dev-ran $PORTLESS_URL" }))
  record.call("run: zero-arg package.json dev script") { tool.run([], timeout: 60) }
  record.call("run: zero-arg --script missing") { tool.run(%w[--script start], timeout: 60) }
  record.call("run: run (infers name from package.json)") { tool.run(%w[run sh -c] + [ "echo $PORTLESS_URL" ]) }
  tool.remove("package.json")
  record.call("proxy: routes.json after runs") do
    { "body" => JSON.pretty_generate(JSON.parse(File.read(File.join(tool.state_dir, "routes.json")))) }
  end
  record.call("proxy: prune with live aliases") { tool.run(%w[prune]) }
  record.call("proxy: doctor --json") { tool.run(%w[doctor --json]) }
  record.call("proxy: alias --remove dead") { tool.run(%w[alias --remove dead]) }
  record.call("proxy: alias --remove dead again") { tool.run(%w[alias --remove dead]) }
  record.call("proxy: alias --remove other.localhost") { tool.run(%w[alias --remove other.localhost]) }
  results["proxy: stop"] = tool.run(%w[proxy stop])
  record.call("proxy: stop again") { tool.run(%w[proxy stop]) }

  tls_env = { "PORTLESS_HTTPS" => nil }
  results["tls: proxy start"] = tool.run(%W[proxy start -p #{PROXY_PORT} --skip-trust], env: tls_env)
  record.call("tls: state files") { { "body" => Dir.children(tool.state_dir).sort.join("\n") } }
  record.call("tls: start again") { tool.run(%W[proxy start -p #{PROXY_PORT} --skip-trust], env: tls_env) }
  record.call("tls: start --no-tls (mismatch)") { tool.run(%W[proxy start -p #{PROXY_PORT} --no-tls], env: tls_env) }
  record.call("tls: get myapp") { tool.run(%w[get myapp], env: tls_env) }
  record.call("tls: alias + list") do
    tool.run(%W[alias dead #{DEAD_PORT}], env: tls_env)
    tool.run(%w[list], env: tls_env)
  end
  sleep 1.5
  record.call("tls: https 404 json") { http("GET", "nope.localhost", tls: true) }
  record.call("tls: https 502 json") { http("GET", "dead.localhost", tls: true) }
  record.call("tls: https 421") { http("GET", "example.com", tls: true) }
  record.call("tls: plain http on tls port") { http("GET", "dead.localhost") }
  record.call("tls: run env") do
    tool.run(%w[myapp sh -c] + [ "echo URL=$PORTLESS_URL SSL=${SSL_CERT_FILE:+set} NODE=${NODE_EXTRA_CA_CERTS:+set}" ],
             env: tls_env)
  end
  record.call("tls: doctor --json") { tool.run(%w[doctor --json], env: tls_env) }
  results["tls: stop"] = tool.run(%w[proxy stop], env: tls_env)
  results
ensure
  tool.run(%w[proxy stop])
end

def normalize_result(tool, result)
  case result
  when Hash then result.to_h { |k, v| [ k, normalize_result(tool, v) ] }
  when Array then result.map { |v| normalize_result(tool, v) }
  when String then tool.normalize(result)
  else result
  end
end

def diff_text(a, b)
  Dir.mktmpdir do |d|
    File.write(File.join(d, "upstream"), a.to_s.end_with?("\n") ? a.to_s : "#{a}\n")
    File.write(File.join(d, "rb"), b.to_s.end_with?("\n") ? b.to_s : "#{b}\n")
    out, = Open3.capture2("diff", "-u", File.join(d, "upstream"), File.join(d, "rb"))
    out.lines.drop(2).join
  end
end

begin
  warn "proxy port #{PROXY_PORT}; upstream state #{UPSTREAM.state_dir}; rb state #{OURS.state_dir}"
  up = collect(UPSTREAM, opts[:only])
  rb = collect(OURS, opts[:only])
  diffs = 0
  (up.keys | rb.keys).each do |name|
    a = normalize_result(UPSTREAM, up[name] || {})
    b = normalize_result(OURS, rb[name] || {})
    if a == b
      puts "SAME  #{name}" if opts[:verbose]
      next
    end
    diffs += 1
    puts "DIFF  #{name}"
    (a.keys | b.keys).each do |field|
      next if a[field] == b[field]

      if a[field].is_a?(String) && b[field].is_a?(String)
        puts "  [#{field}]"
        puts diff_text(a[field], b[field]).gsub(/^/, "    ")
      else
        puts "  [#{field}] upstream=#{a[field].inspect}"
        puts "  [#{field}]       rb=#{b[field].inspect}"
      end
    end
  end
  total = (up.keys | rb.keys).size
  puts "\n#{diffs} of #{total} scenarios differ"
  exit(diffs.zero? ? 0 : 1)
ensure
  UPSTREAM.cleanup
  OURS.cleanup
end
