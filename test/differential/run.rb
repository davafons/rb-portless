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
    s.gsub!(/\b(pid|PID|process group|pgid)\s+\d+/) { "#{Regexp.last_match(1)} <PID>" }
    s.gsub!(/"(pid|registeredAt)":\s*\d+/) { "\"#{Regexp.last_match(1)}\":<N>" }
    s.gsub!(/\bup \d+[smhd]( \d+[smhd])?/, "up <UPTIME>")
    s.gsub!(/\b\d+\.\d+\.\d+(-[\w.]+)?\b/, "<VERSION>")
    s.gsub!(/\d{4}-\d\d-\d\dT[\d:.]+Z/, "<TIME>")
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

def http(method, host, headers: {}, path: "/")
  sock = TCPSocket.new("127.0.0.1", PROXY_PORT)
  lines = [ "#{method} #{path} HTTP/1.1" ]
  lines << "Host: #{host}" if host
  headers.each { |k, v| lines << "#{k}: #{v}" }
  lines << "Connection: close"
  sock.write(lines.join("\r\n") + "\r\n\r\n")
  raw = sock.read
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
  "wildcard strict 404" => [ "GET", "sub.dead.localhost" ]
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
  sleep 1.5 # proxies reload routes.json on a debounce
  record.call("proxy: list") { tool.run(%w[list]) }
  record.call("proxy: list --json") { tool.run(%w[list --json]) }
  record.call("proxy: get dead") { tool.run(%w[get dead]) }
  record.call("proxy: get dead --json") { tool.run(%w[get dead --json]) }
  record.call("proxy: get dead.localhost") { tool.run(%w[get dead.localhost]) }
  record.call("proxy: routes.json") do
    { "body" => JSON.pretty_generate(JSON.parse(File.read(File.join(tool.state_dir, "routes.json")))) }
  end
  HTTP_CASES.each { |name, (m, host, hdrs)| record.call("http: #{name}") { http(m, host, headers: hdrs || {}) } }
  record.call("proxy: prune with live aliases") { tool.run(%w[prune]) }
  record.call("proxy: doctor --json") { tool.run(%w[doctor --json]) }
  record.call("proxy: alias --remove dead") { tool.run(%w[alias --remove dead]) }
  record.call("proxy: alias --remove dead again") { tool.run(%w[alias --remove dead]) }
  record.call("proxy: alias --remove other.localhost") { tool.run(%w[alias --remove other.localhost]) }
  results["proxy: stop"] = tool.run(%w[proxy stop])
  record.call("proxy: stop again") { tool.run(%w[proxy stop]) }
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
