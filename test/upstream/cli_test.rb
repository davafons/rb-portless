# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/cli"

# Mirror of packages/portless/src/cli.test.ts
describe "CLI" do
  include UpstreamCli

  after { assert_system_untouched }

  describe "--help" do
    it "prints help and exits 0 with --help" do
      r = run_cli([ "--help" ])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless"
      _(r.stdout).must_include "Usage:"
      _(r.stdout).must_include "Examples:"
      _(r.stdout).must_include "proxy start"
      _(r.stdout).must_include "service install"
      _(r.stdout).must_include "rb-portless run"
      _(r.stdout).must_include "rb-portless get"
      _(r.stdout).must_include "rb-portless doctor"
      _(r.stdout).wont_include "--prefix <label>"
      _(r.stdout).must_include "Run options: rb-portless run --help"
      section = r.stdout[r.stdout.index("Options:")...r.stdout.index("Environment variables:")]
      zero_arg_options, command_options = section.split("Options for run and <name> <command>:")
      _(zero_arg_options).must_include "--script <name>"
      [ "--name <name>", "--force", "--app-port <number>" ].each do |flag|
        _(zero_arg_options).wont_include flag
        _(command_options).must_include flag
      end
      _(run_cli([ "run", "--help" ]).stdout).must_include "--prefix <label>"
      _(r.stdout).wont_include "--port"
      _(r.stdout).wont_include "--foreground"
      _(r.stdout).must_include "Proxy options: rb-portless proxy --help"
      _(r.stdout).must_include "PORTLESS_APP_PORT"
      _(r.stdout).must_include "PORTLESS_LAN"
      _(r.stdout).must_include "PORTLESS_PREFIX"
      _(r.stdout).must_include "--ngrok"
      _(r.stdout).must_include "--cloudflare"
      _(r.stdout).must_include "rb-portless clean"
    end

    it "keeps proxy startup options in proxy help" do
      r = run_cli([ "proxy", "--help" ])
      _(r.status).must_equal 0
      %w[--port --https --no-tls --cert --key --foreground --tld --wildcard --unprivileged --skip-trust].each do |flag|
        _(r.stdout).must_include flag
      end
    end

    it "prints help and exits 0 with -h" do
      r = run_cli([ "-h" ])
      _(r.status).must_equal 0
      _(r.stdout).must_include "Usage:"
    end

    it "prints help and exits 0 with no args when no dev script exists" do
      tmp = tmpdir("portless-cli-help-")
      File.write(File.join(tmp, "package.json"), JSON.generate(name: "test-app"))
      r = run_cli([], cwd: tmp)
      _(r.status).must_equal 0
      _(r.stdout).must_include "Usage:"
    ensure
      rm_tmp(tmp)
    end
  end

  describe "command help" do
    it "prints help for %j without running the command" do
      [
        [ %w[trust --help], "trust" ],
        [ %w[trust -h], "trust" ],
        [ %w[list --help], "list" ],
        [ %w[proxy start --help], "proxy" ],
        [ %w[prune --force --help], "prune" ],
        [ %w[hosts sync --help], "hosts" ],
        [ %w[service install --help], "service" ],
        [ %w[alias --help --bogus], "alias" ],
        [ %w[alias --remove --help], "alias" ]
      ].each do |args, command|
        tmp = tmpdir("portless-command-help-")
        bin = File.join(tmp, "bin")
        home = File.join(tmp, "home")
        state = File.join(tmp, "state")
        [ bin, home, state ].each { |d| Dir.mkdir(d) }
        routes = JSON.generate([ { hostname: "stale.localhost", port: 4999, pid: 999_999 } ])
        File.write(File.join(state, "routes.json"), routes)
        r = run_cli(args, cwd: tmp, env: { "PATH" => bin, "HOME" => home, "PORTLESS_STATE_DIR" => state, "PORTLESS" => nil })
        _(r.status).must_equal 0, "#{args.inspect}: #{r.stderr}"
        _(r.stdout.lstrip).must_match(/\Arb-portless #{command} - /)
        _(Dir.children(state)).must_equal [ "routes.json" ]
        _(File.read(File.join(state, "routes.json"))).must_equal routes
      ensure
        rm_tmp(tmp)
      end
    end

    it "prints help for %j, a command that wraps nothing" do
      Portless::Commands::COMMAND_NAMES.reject { |n| %w[run compose].include?(n) }.flat_map do |name|
        [ [ [ name, "--", "--help" ], name ], [ [ name, "--", "-h" ], name ], [ [ name, "--bogus", "--help" ], name ] ]
      end.each do |args, command|
        tmp = tmpdir("portless-command-help-")
        bin = File.join(tmp, "bin")
        home = File.join(tmp, "home")
        state = File.join(tmp, "state")
        [ bin, home, state ].each { |d| Dir.mkdir(d) }
        r = run_cli(args, cwd: tmp, env: { "PATH" => bin, "HOME" => home, "PORTLESS_STATE_DIR" => state, "PORTLESS" => nil })
        _(r.status).must_equal 0, "#{args.inspect}: #{r.stderr}"
        _(r.stderr).must_equal ""
        _(r.stdout).must_include "rb-portless #{command}"
        _(Dir.children(state)).must_equal []
      ensure
        rm_tmp(tmp)
      end
    end

    it "passes --help after a compose subcommand to Docker Compose" do
      tmp = tmpdir("portless-compose-help-")
      write_exe(File.join(tmp, "docker"), "#!/bin/sh\necho \"docker $*\"\n")
      r = run_cli(%w[compose up --help], env: { "PATH" => tmp, "PORTLESS" => nil })
      _(r.status).must_equal 0
      _(r.stdout).must_include "docker compose up --help"
    ensure
      rm_tmp(tmp)
    end
  end

  describe "color per stream" do
    def run_with_terminal(terminal, args)
      tmp = tmpdir("portless-color-")
      preload = File.join(tmp, "terminal.rb")
      File.write(preload, "$#{terminal}.define_singleton_method(:tty?) { true }\n$#{terminal}.define_singleton_method(:isatty) { true }\n")
      env = ENV.to_h.merge("HOME" => tmp, "USERPROFILE" => tmp, "PORTLESS_STATE_DIR" => tmp)
      %w[NO_COLOR FORCE_COLOR PORTLESS PNPM_SCRIPT_SRC_DIR].each { |n| env.delete(n) }
      env.delete("npm_command") if env["npm_command"] == "exec"
      run_cli(args, base_env: env, cwd: tmp, ruby_opts: [ "-r", preload ])
    ensure
      rm_tmp(tmp)
    end

    it "keeps color codes out of a redirected stderr when stdout is a terminal" do
      error = run_with_terminal("stdout", %w[list --bogus])
      _(error.status).must_equal 2
      _(error.stderr).must_include "Unknown flag"
      _(error.stderr).wont_include "\e["
      _(run_with_terminal("stdout", [ "--help" ]).stdout).must_include "\e[1m"
    end

    it "keeps color codes out of a redirected stdout when stderr is a terminal" do
      help = run_with_terminal("stderr", [ "--help" ])
      _(help.status).must_equal 0
      _(help.stdout).must_include "rb-portless"
      _(help.stdout).wont_include "\e["
      _(run_with_terminal("stderr", %w[list --bogus]).stderr).must_include "\e[31m"
    end
  end

  describe "--version" do
    it "prints version and exits 0 with --version" do
      r = run_cli([ "--version" ])
      _(r.status).must_equal 0
      _(r.stdout.strip).must_match(/\A\d+\.\d+\.\d+/)
    end

    it "prints version and exits 0 with -v" do
      r = run_cli([ "-v" ])
      _(r.status).must_equal 0
      _(r.stdout.strip).must_match(/\A\d+\.\d+\.\d+/)
    end
  end

  describe "list" do
    it "prints JSON for empty and registered routes and rejects unknown arguments" do
      tmp = tmpdir("portless-list-json-")
      options = { cwd: tmp, env: { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_HTTPS" => "0" } }
      empty = run_cli(%w[list --json], **options)
      _(empty.status).must_equal 0
      _(JSON.parse(empty.stdout)).must_equal({ "routes" => [] })
      route = { "hostname" => "db.localhost", "port" => 5432, "pid" => 0, "registeredAt" => 123 }
      File.write(File.join(tmp, "routes.json"), JSON.generate([ route ]))
      json = run_cli(%w[list --json], **options)
      human = run_cli(%w[list], **options)
      _(json.status).must_equal 0
      listed = JSON.parse(json.stdout)["routes"]
      _(listed.length).must_equal 1
      _(listed[0].except("url")).must_equal route
      _(listed[0]["url"]).must_match(%r{\Ahttp://db\.localhost})
      _(human.stdout).must_include listed[0]["url"]
      _(human.stdout).must_include "localhost:5432"
      invalid = run_cli(%w[list --bogus], **options)
      _(invalid.status).must_equal 2
      _(invalid.stderr).must_include 'Error: Unknown flag "--bogus" for rb-portless list.'
    ensure
      rm_tmp(tmp)
    end

    it "exits 1 with empty stdout when routes.json is corrupt" do
      tmp = tmpdir("portless-list-corrupt-")
      File.write(File.join(tmp, "routes.json"), "{")
      options = { cwd: tmp, env: { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_HTTPS" => "0" } }
      json = run_cli(%w[list --json], **options)
      _(json.status).must_equal 1
      _(json.stdout).must_equal ""
      _(json.stderr).must_include "Corrupted routes file (invalid JSON)"
      human = run_cli(%w[list], **options)
      _(human.status).must_equal 1
      _(human.stdout).must_equal ""
    ensure
      rm_tmp(tmp)
    end

    it "includes upstream settings from real aliases in JSON" do
      tmp = tmpdir("portless-list-json-upstream-")
      options = { cwd: tmp, env: { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_HTTPS" => "0", "PORTLESS_SYNC_HOSTS" => "0",
                                   "PORTLESS_TLD" => "localhost" } }
      _(run_cli(%w[alias tls 7443 --upstream https --tld localhost], **options).status).must_equal 0
      _(run_cli(%w[alias plain 8080 --upstream http://api.internal --tld localhost], **options).status).must_equal 0
      _(run_cli(%w[alias authority 9443 --upstream https://api.internal:8443 --tld localhost], **options).status).must_equal 0
      _(run_cli(%w[alias direct 5432 --tld localhost], **options).status).must_equal 0

      result = run_cli(%w[list --json], **options)
      _(result.status).must_equal 0
      listed = JSON.parse(result.stdout)
      route = ->(hostname) { listed["routes"].find { |e| e["hostname"] == hostname } }
      _(route.("tls.localhost")["upstream"]).must_equal({ "tls" => true })
      _(route.("plain.localhost")["upstream"]).must_equal({ "tls" => false, "host" => "api.internal" })
      _(route.("authority.localhost")["upstream"]).must_equal({ "tls" => true, "host" => "api.internal:8443" })
      _(route.("direct.localhost").key?("upstream")).must_equal false
    ensure
      rm_tmp(tmp)
    end

    it "shows no active routes message when none registered" do
      r = run_cli(%w[list])
      _(r.status).must_equal 0
    end

    it "appends uptime after the pid and leaves aliases and legacy routes unchanged" do
      tmp = tmpdir("portless-list-uptime-")
      proxy_port = get_free_port
      now_ms = (Time.now.to_f * 1000).to_i
      File.write(File.join(tmp, "routes.json"), JSON.generate([
        { hostname: "app.localhost", port: 4001, pid: Process.pid, registeredAt: now_ms - (3 * 60 * 60 * 1000) },
        { hostname: "docker.localhost", port: 4002, pid: 0 },
        { hostname: "tls.localhost", port: 4004, pid: 0, upstream: { tls: true, host: "api.internal:8443" } },
        { hostname: "plain.localhost", port: 4005, pid: 0, upstream: { tls: false, host: "api.internal" } },
        { hostname: "tls-default.localhost", port: 4006, pid: 0, upstream: { tls: true } },
        { hostname: "legacy.localhost", port: 4003, pid: Process.pid }
      ]))
      r = run_cli(%w[list], env: { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_HTTPS" => "0" })
      _(r.status).must_equal 0
      lines = r.stdout.split("\n")
      row = ->(host) { lines.find { |l| l.include?(host) }.lstrip }
      _(row.("app.localhost")).must_match(/ {2}\(pid \d+\) up 3h\z/)
      _(row.("docker.localhost")).must_match(/ {2}\(alias\)\z/)
      _(row.("tls.localhost")).must_include "https://localhost:4004"
      _(row.("plain.localhost")).must_include "http://localhost:4005"
      _(row.("tls-default.localhost")).must_include "https://localhost:4006"
      _(lines.any? { |l| l.strip == "Host: api.internal:8443" }).must_equal true
      _(lines.any? { |l| l.strip == "Host: api.internal" }).must_equal true
      _(row.("legacy.localhost")).must_match(/ {2}\(pid \d+\)\z/)
    ensure
      rm_tmp(tmp)
    end
  end

  describe "prune" do
    def read_raw(path) = JSON.parse(File.read(path))
    def now_ms = (Time.now.to_f * 1000).to_i

    it "keeps a surviving orphan for prune --force" do
      if RUBY_PLATFORM.include?("darwin")
        skip "macOS /bin/sh execs its single command, so the listener is the group leader and is never " \
             "recorded as the survivor; upstream fails here on macOS too (passes with Linux dash)"
      end
      tmp = tmpdir("portless-prune-retry-")
      child = spawn_bg([ "sh", "-c", '"$1" -rsocket -e "$2"', "sh", RbConfig.ruby,
                         'trap("TERM"){}; s=TCPServer.new("127.0.0.1",0); puts s.addr[1]; $stdout.flush; sleep' ],
                       detached: true)
      tunnels = []
      tailscale_log = File.join(tmp, "tailscale.log")
      write_tailscale_shim(tmp)
      env = { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_TEST_TAILSCALE_LOG" => tailscale_log,
              "PATH" => "#{tmp}#{File::PATH_SEPARATOR}#{ENV['PATH']}" }
      %w[ngrok cloudflared].each { |binary| tunnels << spawn_fake_binary(tmp, binary) }
      port = Integer(child.read_line)
      child_pgid = child.pid
      child_start_time = get_process_start_time(child_pgid)
      _(child_start_time).wont_be_nil
      routes_path = File.join(tmp, "routes.json")
      File.write(routes_path, JSON.generate([
        { hostname: "retry.localhost", port: port, pid: 999_999, childPgid: child_pgid, childStartTime: child_start_time,
          tailscaleHttpsPort: 8443, ngrokPid: tunnels[0].pid, cloudflarePid: tunnels[1].pid }
      ]))
      first = run_cli(%w[prune], env: env)
      _(first.status).must_equal 0
      _(first.stdout).must_include "did not exit"
      _(first.stdout).must_include "rb-portless prune --force"
      raw = read_raw(routes_path)
      _(raw.length).must_equal 1
      _(raw[0]).must_be :>=, { "hostname" => "retry.localhost", "port" => port, "childPgid" => child_pgid,
                               "orphanPid" => find_pids_on_port(port)[0] }
      _(raw[0]["orphanStartTime"]).must_be_kind_of String
      _(File.exist?(tailscale_log)).must_equal false
      tunnels.each { |t| _(alive_pid?(t.pid)).must_equal true }
      _(first.stdout).wont_include "stopped"
      other = run_cli([ "alias", "unrelated.localhost", get_free_port.to_s ], env: env)
      _(other.status).must_equal 0, other.stderr
      _(read_raw(routes_path).count { |r| r["pid"] == 999_999 }).must_equal 1
      second = run_cli(%w[prune --force], env: env)
      _(second.status).must_equal 0
      _(read_raw(routes_path).select { |r| r["pid"] == 999_999 }).must_equal []
      _(find_pids_on_port(port)).must_equal []
      _(File.read(tailscale_log)).must_include "serve --yes --https=8443 off"
      _(second.stdout).must_include "stopped ngrok tunnel"
      _(second.stdout).must_include "stopped Cloudflare tunnel"
      raw = read_raw(routes_path)
      _(raw.length).must_equal 1
      _(raw[0]).must_be :>=, { "hostname" => "unrelated.localhost", "pid" => 0 }
      tunnels.each do |t|
        t.wait(10)
        _(alive_pid?(t.pid)).must_equal false
      end
    ensure
      tunnels&.each(&:kill)
      kill_group(child.pid) if child
      rm_tmp(tmp)
    end

    it "records a route whose group leader exited, then stops it on retry" do
      tmp = tmpdir("portless-prune-leader-gone-")
      routes_path = File.join(tmp, "routes.json")
      tailscale_log = File.join(tmp, "tailscale.log")
      write_tailscale_shim(tmp)
      dead_records = -> { read_raw(routes_path).select { |r| r["pid"] == 999_999 } }
      helper = 'TCPServer.new("127.0.0.1", Integer(ARGV[0])); sleep'
      port = get_free_port
      leader = spawn_bg([ "sh", "-c", '"$1" -rsocket -e "$2" "$3" &', "sh", RbConfig.ruby, helper, port.to_s ],
                        detached: true, out: false, reap: false)
      leader_pid = leader.pid
      leader_start_time = get_process_start_time(leader_pid)
      env = { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_TEST_TAILSCALE_LOG" => tailscale_log,
              "PATH" => "#{tmp}#{File::PATH_SEPARATOR}#{ENV['PATH']}" }
      leader.wait
      holder_pid = wait_until(5) { find_pids_on_port(port)[0] }
      _(holder_pid).must_be_kind_of Integer
      _(leader_start_time).wont_be_nil
      File.write(routes_path, JSON.generate([
        { hostname: "leader-gone.localhost", port: port, pid: 999_999, childPgid: leader_pid,
          childStartTime: leader_start_time, tailscaleHttpsPort: 8443, registeredAt: now_ms - 60_000 }
      ]))

      first = run_cli(%w[prune], env: env)
      _(first.status).must_equal 0, first.stderr
      _(first.stdout).must_include "outlived its leader"
      _(first.stdout).must_include "process #{holder_pid} recorded"
      _(first.stdout).must_include "skipped 1 route"
      _(first.stdout).wont_include "tailscale"
      dead = dead_records.()
      _(dead.length).must_equal 1
      _(dead[0]).must_be :>=, { "hostname" => "leader-gone.localhost", "port" => port, "childPgid" => leader_pid,
                                "orphanPid" => holder_pid }
      _(dead[0]["orphanStartTime"]).must_be_kind_of String
      _(find_pids_on_port(port)).must_equal [ holder_pid ]
      _(File.exist?(tailscale_log)).must_equal false

      _(run_cli([ "alias", "add-other.localhost", get_free_port.to_s ], env: env).status).must_equal 0
      _(run_cli([ "alias", "leader-gone.localhost", get_free_port.to_s ], env: env).status).must_equal 0
      _(dead_records.().length).must_equal 1

      retried = run_cli(%w[prune --force], env: env)
      _(retried.status).must_equal 0, retried.stderr
      _(retried.stdout).must_include "killed process group"
      _(retried.stdout).must_include "route removed"
      _(dead_records.()).must_equal []
      wait_until(5) { find_pids_on_port(port).empty? }
      _(find_pids_on_port(port)).must_equal []
      _(File.read(tailscale_log)).must_include "serve --yes --https=8443 off"
      _(read_raw(routes_path).any? { |r| r["hostname"] == "leader-gone.localhost" && r["pid"] == 0 }).must_equal true
    ensure
      kill_group(leader_pid) if leader_pid
      rm_tmp(tmp)
    end

    it "keeps a group that ignores SIGTERM after it releases the port" do
      tmp = tmpdir("portless-prune-port-closed-")
      routes_path = File.join(tmp, "routes.json")
      tailscale_log = File.join(tmp, "tailscale.log")
      write_tailscale_shim(tmp)
      env = { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_TEST_TAILSCALE_LOG" => tailscale_log,
              "PATH" => "#{tmp}#{File::PATH_SEPARATOR}#{ENV['PATH']}" }
      leader = spawn_bg([ RbConfig.ruby, "-rsocket", "-e",
                          's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; $stdout.flush; ' \
                          'trap("TERM") { Thread.new { s.close rescue nil } }; sleep' ], detached: true)
      child_pgid = leader.pid
      child_start_time = get_process_start_time(child_pgid)
      port = Integer(leader.read_line)
      _(child_start_time).wont_be_nil
      registered_at = now_ms - 60_000
      File.write(routes_path, JSON.generate([
        { hostname: "stuck.localhost", port: port, pid: 999_999, childPgid: child_pgid, childStartTime: child_start_time,
          tailscaleHttpsPort: 8443, registeredAt: registered_at },
        { hostname: "stuck-alt.localhost", port: port, pid: 999_999, childPgid: child_pgid,
          childStartTime: child_start_time, registeredAt: registered_at }
      ]))

      first = run_cli(%w[prune], env: env)
      _(first.status).must_equal 0, first.stderr
      _(first.stdout).must_include "did not exit"
      _(first.stdout).wont_include "killed process group"
      _(first.stdout).must_include "Pruned 0 stale routes, killed 0 orphaned processes, skipped 2 routes"
      wait_until(5) { find_pids_on_port(port).empty? }
      _(find_pids_on_port(port)).must_equal []
      _(alive_pid?(child_pgid)).must_equal true
      _(read_raw(routes_path).length).must_equal 2
      _(File.exist?(tailscale_log)).must_equal false

      forced = run_cli(%w[prune --force], env: env)
      _(forced.status).must_equal 0, forced.stderr
      _(forced.stdout).must_include "killed process group #{child_pgid} (SIGKILL)"
      _(forced.stdout).must_include "Pruned 2 stale routes, killed 1 orphaned process"
      _(read_raw(routes_path)).must_equal []
      _(File.read(tailscale_log)).must_include "serve --yes --https=8443 off"
    ensure
      kill_group(child_pgid) if child_pgid
      rm_tmp(tmp)
    end

    it "records the member that outlived its leader after the port closed, then stops it" do
      tmp = tmpdir("portless-prune-member-kept-")
      routes_path = File.join(tmp, "routes.json")
      leader = spawn_bg([ "sh", "-c", '"$1" -rsocket -e "$2" & wait', "sh", RbConfig.ruby,
                          's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; $stdout.flush; ' \
                          'trap("TERM") { Thread.new { s.close rescue nil } }; sleep' ], detached: true)
      child_pgid = leader.pid
      child_start_time = get_process_start_time(child_pgid)
      port = Integer(leader.read_line)
      _(child_start_time).wont_be_nil
      member_pid = find_pids_on_port(port)[0]
      _(member_pid).must_be_kind_of Integer
      File.write(routes_path, JSON.generate([
        { hostname: "member-stuck.localhost", port: port, pid: 999_999, childPgid: child_pgid,
          childStartTime: child_start_time, registeredAt: now_ms - 60_000 }
      ]))

      first = run_cli(%w[prune], env: { "PORTLESS_STATE_DIR" => tmp })
      _(first.status).must_equal 0, first.stderr
      _(first.stdout).must_include "did not exit"
      _(first.stdout).wont_include "killed process group"
      wait_until(5) { find_pids_on_port(port).empty? }
      _(find_pids_on_port(port)).must_equal []
      raw = read_raw(routes_path)
      _(raw.length).must_equal 1
      _(raw[0]).must_be :>=, { "hostname" => "member-stuck.localhost", "childPgid" => child_pgid, "orphanPid" => member_pid }
      _(raw[0]["orphanStartTime"]).must_be_kind_of String
      _(alive_pid?(member_pid)).must_equal true

      forced = run_cli(%w[prune --force], env: { "PORTLESS_STATE_DIR" => tmp })
      _(forced.status).must_equal 0, forced.stderr
      _(forced.stdout).must_include "killed process group #{child_pgid} (SIGKILL)"
      _(read_raw(routes_path)).must_equal []
      wait_until(5) { !alive_pid?(member_pid) }
      _(alive_pid?(member_pid)).must_equal false
    ensure
      kill_group(child_pgid) if child_pgid
      rm_tmp(tmp)
    end

    it "keeps a group it cannot verify and never kills it" do
      tmp = tmpdir("portless-prune-unverified-")
      routes_path = File.join(tmp, "routes.json")
      pid_file = File.join(tmp, "member.pid")
      leader = spawn_bg([ "sh", "-c", '"$1" -e "$2" & echo $! > "$3"', "sh", RbConfig.ruby, "sleep", pid_file ],
                        detached: true, out: false)
      child_pgid = leader.pid
      leader.wait
      member_pid = Integer(File.read(pid_file))
      File.write(routes_path, JSON.generate([
        { hostname: "unverifiable.localhost", port: get_free_port, pid: 999_999, childPgid: child_pgid,
          childStartTime: "Thu Jan  1 00:00:00 1970", registeredAt: now_ms - 60_000 }
      ]))

      [ %w[prune], %w[prune --force] ].each do |args|
        result = run_cli(args, env: { "PORTLESS_STATE_DIR" => tmp })
        _(result.status).must_equal 0, result.stderr
        _(result.stdout).must_include "process group #{child_pgid} could not be verified"
        _(result.stdout).must_include "killed 0 orphaned processes"
        _(alive_pid?(member_pid)).must_equal true
        raw = read_raw(routes_path)
        _(raw.length).must_equal 1
        _(raw[0]).must_be :>=, { "hostname" => "unverifiable.localhost", "childPgid" => child_pgid }
      end
    ensure
      kill_group(child_pgid) if child_pgid
      rm_tmp(tmp)
    end

    it "never records a holder of a group whose leader identity still mismatches" do
      tmp = tmpdir("portless-prune-recycled-")
      routes_path = File.join(tmp, "routes.json")
      leader = spawn_bg([ RbConfig.ruby, "-rsocket", "-e",
                          's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; $stdout.flush; sleep' ], detached: true)
      child_pgid = leader.pid
      port = Integer(leader.read_line)
      File.write(routes_path, JSON.generate([
        { hostname: "recycled.localhost", port: port, pid: 999_999, childPgid: child_pgid,
          childStartTime: "Thu Jan  1 00:00:00 1970", registeredAt: now_ms - 60_000 }
      ]))

      [ %w[prune], %w[prune --force] ].each do |args|
        result = run_cli(args, env: { "PORTLESS_STATE_DIR" => tmp })
        _(result.status).must_equal 0, result.stderr
        _(result.stdout).must_include "process group #{child_pgid} could not be verified"
        _(result.stdout).must_include "killed 0 orphaned processes"
        _(result.stdout).wont_include "outlived its leader"
        routes = read_raw(routes_path)
        _(routes.length).must_equal 1
        _(routes[0]).must_be :>=, { "hostname" => "recycled.localhost", "childPgid" => child_pgid,
                                    "childStartTime" => "Thu Jan  1 00:00:00 1970" }
        _(routes[0].key?("orphanPid")).must_equal false
        _(alive_pid?(child_pgid)).must_equal true
        _(find_pids_on_port(port)).must_equal [ child_pgid ]
      end
    ensure
      kill_group(child_pgid) if child_pgid
      rm_tmp(tmp)
    end

    it "leaves a tailscale serve alone while a live route owns its port" do
      tmp = tmpdir("portless-prune-tailscale-")
      routes_path = File.join(tmp, "routes.json")
      tailscale_log = File.join(tmp, "tailscale.log")
      write_tailscale_shim(tmp)
      env = { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_TEST_TAILSCALE_LOG" => tailscale_log,
              "PATH" => "#{tmp}#{File::PATH_SEPARATOR}#{ENV['PATH']}" }
      stale_on_port = lambda do |https_port, live_https_port = nil|
        live = { hostname: "live.localhost", port: get_free_port, pid: 0 }
        live[:tailscaleHttpsPort] = live_https_port unless live_https_port.nil?
        live[:registeredAt] = now_ms
        File.write(routes_path, JSON.generate([
          { hostname: "dead.localhost", port: get_free_port, pid: 999_999, tailscaleHttpsPort: https_port,
            registeredAt: now_ms - 60_000 },
          live
        ]))
        result = run_cli(%w[prune], env: env)
        _(result.status).must_equal 0, result.stderr
        _(result.stdout).must_include "route removed"
        File.exist?(tailscale_log) ? File.read(tailscale_log) : ""
      end
      _(stale_on_port.(8443, 8443)).must_equal ""
      FileUtils.rm_f(tailscale_log)
      _(stale_on_port.(8443)).must_include "serve --yes --https=8443 off"
    ensure
      rm_tmp(tmp)
    end

    it "removes a stale route without killing an unrelated process on its port" do
      tmp = tmpdir("portless-prune-safe-")
      listener = TCPServer.new("127.0.0.1", 0)
      route = { hostname: "stale.localhost", port: listener.addr[1], pid: 999_999, childPgid: 999_999,
                childStartTime: "leader-start", registeredAt: now_ms - 60_000 }
      routes_path = File.join(tmp, "routes.json")
      File.write(routes_path, JSON.generate([ route ]))

      first = run_cli(%w[prune], env: { "PORTLESS_STATE_DIR" => tmp })
      _(first.status).must_equal 0
      _(first.stdout).must_include "still holds the port and was not killed"
      _(first.stdout).wont_include "recorded"
      _(listener.closed?).must_equal false
      _(read_raw(routes_path)).must_equal []
    ensure
      listener&.close
      rm_tmp(tmp)
    end

    it "drops a stale recovery record once its orphaned group and tunnel are gone" do
      tmp = tmpdir("portless-start-recovery-")
      routes_path = File.join(tmp, "routes.json")
      tunnel = spawn_fake_binary(tmp, "ngrok")
      env = { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_PORT" => get_free_port.to_s, "PORTLESS_HTTPS" => "0" }
      File.write(routes_path, JSON.generate([
        { hostname: "stale.localhost", port: get_free_port, pid: 999_999, childPgid: 999_999,
          childStartTime: "leader-start", ngrokPid: tunnel.pid, registeredAt: now_ms - 60_000 }
      ]))

      result = run_cli([ "myapp", RbConfig.ruby, "-e", "exit 0" ], env: env, timeout: 30)

      _(result.status).must_equal 0, result.stderr
      _(result.stderr).must_include "Stopped orphaned ngrok tunnel"
      _(read_raw(routes_path)).must_equal []
      tunnel.wait(10)
      _(alive_pid?(tunnel.pid)).must_equal false
    ensure
      tunnel&.kill
      run_cli(%w[proxy stop], env: env) if env
      rm_tmp(tmp)
    end
  end

  describe "corrupt routes file recovery" do
    it "quarantines the file and starts the proxy" do
      state = tmpdir("portless-corrupt-proxy-")
      port = get_free_port
      env = { "PORTLESS_STATE_DIR" => state, "PORTLESS_HTTPS" => "0", "PORTLESS_PORT" => port.to_s }
      File.write(File.join(state, "routes.json"), "{")
      start = run_cli([ "proxy", "start", "--no-tls", "-p", port.to_s ], env: env, timeout: 30)
      _(start.status).must_equal 0, start.stdout + start.stderr
      _(start.stderr).must_include "Moved corrupted routes file"
      _(Dir.children(state).any? { |f| f.start_with?("routes.json.corrupt-") }).must_equal true
      listed = run_cli(%w[list --json], env: env)
      _(listed.status).must_equal 0
      _(JSON.parse(listed.stdout)).must_equal({ "routes" => [] })
    ensure
      run_cli([ "proxy", "stop", "--port", port.to_s ], env: env) if env
      rm_tmp(state)
    end

    it "runs a named app when the file is corrupt" do
      root = tmpdir("portless-corrupt-app-")
      state = tmpdir("portless-corrupt-app-state-")
      port = get_free_port
      env = { "PORTLESS_STATE_DIR" => state, "PORTLESS_HTTPS" => "0", "PORTLESS_PORT" => port.to_s, "NO_COLOR" => "1" }
      ENV.each_key { |k| env[k] = nil if k.start_with?("npm_", "PNPM_") }
      File.write(File.join(root, "server.rb"), UpstreamCli::APP_SERVER)
      File.write(File.join(state, "routes.json"), "{")
      child = spawn_bg(cli_argv("myapp", RbConfig.ruby, "server.rb"), env: env, chdir: root, detached: true)
      routes = []
      60.times do
        listed = run_cli(%w[list --json], env: env)
        routes = JSON.parse(listed.stdout)["routes"] if listed.status.zero?
        break unless routes.empty?

        sleep 0.25
      end
      _(routes.length).must_equal 1, child.output
      _(routes[0]["hostname"]).must_include "myapp"
      _(child.output).must_include "Moved corrupted routes file"
    ensure
      stop_child(child) if child
      kill_group(child.pid) if child
      run_cli([ "proxy", "stop", "--port", port.to_s ], env: env) if env
      rm_tmp(root)
      rm_tmp(state)
    end
  end

  describe "doctor" do
    def doctor_env(dir, port) = { "PORTLESS_STATE_DIR" => dir, "PORTLESS_PORT" => port.to_s, "PORTLESS_HTTPS" => "0" }
    def not_portless = http_server { [ 200, {}, "not portless" ] }

    it "prints help with --help" do
      r = run_cli(%w[doctor --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless doctor"
      _(r.stdout).must_include "state"
      _(r.stdout).must_include "does not start"
      _(r.stdout).must_include "Exit codes:"
      _(r.stdout).must_match(/2\s+Invalid arguments/)
    end

    it "reports a stopped proxy as a warning and exits 0" do
      tmp = tmpdir("portless-doctor-stopped-")
      proxy_port = get_free_port
      r = run_cli(%w[doctor], env: doctor_env(tmp, proxy_port))
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless doctor"
      _(r.stdout).must_include "Proxy is not running on port #{proxy_port}"
      _(r.stdout).must_include "Summary: 0 failures"
    ensure
      rm_tmp(tmp)
    end

    it "prints the report as JSON with --json and exits 0 when nothing fails" do
      tmp = tmpdir("portless-doctor-json-")
      proxy_port = get_free_port
      r = run_cli(%w[doctor --json], env: doctor_env(tmp, proxy_port))
      _(r.status).must_equal 0
      report = JSON.parse(r.stdout)
      _(r.stdout.strip).must_equal JSON.generate(report)
      # rubyVersion stands in for upstream's nodeVersion (the runtime's version).
      _(report.keys.sort).must_equal %w[findings mode platform proxyTarget rubyVersion stateDir summary version]
      _(report["version"]).must_match(/\A\d+\.\d+\.\d+/)
      _(report["rubyVersion"]).must_equal RUBY_VERSION
      _(report["platform"]).must_equal "#{Portless::Doctor.node_platform} #{Portless::Doctor.node_arch}"
      _(File.realpath(report["stateDir"])).must_equal File.realpath(tmp)
      _(report["proxyTarget"]).must_equal "http://127.0.0.1:#{proxy_port}"
      _(report["mode"]).must_equal "HTTP, .localhost"
      _(report["findings"].length).must_be :>, 0
      report["findings"].each do |finding|
        _(%w[ok warn fail info]).must_include finding["status"]
        _(finding["message"]).must_be_kind_of String
        _(finding["hint"]).must_be_kind_of String if finding.key?("hint")
      end
      _(report["summary"]).must_equal({ "failures" => report["findings"].count { |f| f["status"] == "fail" },
                                        "warnings" => report["findings"].count { |f| f["status"] == "warn" } })
      _(report["summary"]["failures"]).must_equal 0
      _(r.stderr).wont_include '"findings"'
    ensure
      rm_tmp(tmp)
    end

    it "keeps stdout to JSON and exits 1 when a check fails with --json" do
      tmp = tmpdir("portless-doctor-json-fail-")
      server = not_portless
      proxy_port = server.port
      r = run_cli(%w[doctor --json], env: doctor_env(tmp, proxy_port))
      _(r.status).must_equal 1
      report = JSON.parse(r.stdout)
      _(r.stdout.strip).must_equal JSON.generate(report)
      failures = report["findings"].select { |f| f["status"] == "fail" }
      _(report["summary"]).must_equal({ "failures" => failures.length,
                                        "warnings" => report["findings"].count { |f| f["status"] == "warn" } })
      _(failures.length).must_be :>, 0
      _(failures.any? { |f| f["message"].include?("Port #{proxy_port} is in use, but it is not a rb-portless proxy") }).must_equal true
    ensure
      server&.close
      rm_tmp(tmp)
    end

    it "flushes a large failed JSON report when stdout is paused" do
      tmp = tmpdir("portless-doctor-json-pipe-")
      server = not_portless
      proxy_port = server.port
      File.write(File.join(tmp, "proxy.lan"), "192.0.2.1\n")
      File.write(File.join(tmp, "routes.json"),
                 JSON.generate(Array.new(3000) { |i| { hostname: "route-#{i}.localhost", port: 70_000, pid: 0 } }))
      env = ENV.to_h
      env.delete("PNPM_SCRIPT_SRC_DIR")
      env.delete("npm_command") if env["npm_command"] == "exec"
      env.merge!("NO_COLOR" => "1", "PORTLESS_STATE_DIR" => tmp, "PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_HTTPS" => "0")
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(env, *cli_argv("doctor", "--json"), in: File::NULL, out: out_w, err: err_w)
      out_w.close
      err_w.close
      stderr_reader = Thread.new { err_r.read }
      stdout = +out_r.readpartial(65_536)
      sleep 0.3 # paused reader
      stdout << out_r.read
      _, status = Process.wait2(pid)
      pid = nil
      stderr = stderr_reader.value

      _([ status.exitstatus, status.termsig ]).must_equal [ 1, nil ]
      _(stderr).wont_include '"findings"'
      _(stdout.bytesize).must_be :>, 256 * 1024
      report = JSON.parse(stdout)
      _(stdout.strip).must_equal JSON.generate(report)
      _(report["findings"].length).must_be :>=, 3000
      _(report["summary"]["failures"]).must_be :>, 0
      _(report["findings"].any? { |f| f["message"].include?("Port #{proxy_port} is in use, but it is not a rb-portless proxy") }).must_equal true
    ensure
      Process.kill("KILL", pid) rescue nil if pid
      server&.close
      rm_tmp(tmp)
    end

    it "exits 2 with empty stdout for an unknown flag with --json" do
      r = run_cli(%w[doctor --json --bogus])
      _(r.status).must_equal 2
      _(r.stdout).must_equal ""
      _(r.stderr).must_include 'Error: Unknown flag "--bogus" for rb-portless doctor.'
    end

    it "does not fail for a missing nested state directory with a writable ancestor" do
      tmp_root = tmpdir("portless-doctor-nested-")
      proxy_port = get_free_port
      state_dir = File.join(tmp_root, "missing", "state")
      r = run_cli(%w[doctor], env: doctor_env(state_dir, proxy_port))
      _(r.status).must_equal 0
      _(r.stdout).must_include "State directory has not been created yet: #{state_dir}"
      _(r.stdout).must_include "Summary: 0 failures"
    ensure
      rm_tmp(tmp_root)
    end

    it "does not require OpenSSL when persisted proxy state is HTTP" do
      tmp = tmpdir("portless-doctor-http-")
      proxy_port = get_free_port
      File.write(File.join(tmp, "proxy.port"), proxy_port.to_s)
      r = run_cli(%w[doctor], env: { "PORTLESS_STATE_DIR" => tmp, "PATH" => tmp })
      _(r.status).must_equal 0
      _(r.stdout).must_include "HTTPS is disabled for the current proxy state."
      _(r.stdout).wont_include "OpenSSL is not available"
    ensure
      rm_tmp(tmp)
    end

    it "does not require generated CA checks when proxy state uses a custom certificate" do
      tmp = tmpdir("portless-doctor-custom-cert-")
      proxy_port = get_free_port
      File.write(File.join(tmp, "proxy.port"), proxy_port.to_s)
      File.write(File.join(tmp, "proxy.tls"), "1")
      File.write(File.join(tmp, "proxy.custom-cert"), "1")
      r = run_cli(%w[doctor], env: { "PORTLESS_STATE_DIR" => tmp, "PATH" => tmp })
      _(r.status).must_equal 0
      _(r.stdout).must_include "Proxy is configured with a custom TLS certificate."
      _(r.stdout).must_include "Generated local CA is not required for custom TLS certificates."
      _(r.stdout).wont_include "OpenSSL is not available"
      _(r.stdout).wont_include "Generated CA file is missing"
      _(r.stdout).wont_include "Local CA has not been generated"
    ensure
      rm_tmp(tmp)
    end

    it "exits 1 when the proxy port is occupied by a non-portless process" do
      tmp = tmpdir("portless-doctor-conflict-")
      server = not_portless
      proxy_port = server.port
      r = run_cli(%w[doctor], env: doctor_env(tmp, proxy_port))
      _(r.status).must_equal 1
      _(r.stdout).must_include "Port #{proxy_port} is in use, but it is not a rb-portless proxy"
      _(r.stdout).must_include "Summary: 1 failure"
    ensure
      server&.close
      rm_tmp(tmp)
    end

    it "fails doctor when routes.json is corrupted" do
      tmp = tmpdir("portless-doctor-routes-")
      proxy_port = get_free_port
      File.write(File.join(tmp, "routes.json"), "{")
      r = run_cli(%w[doctor], env: doctor_env(tmp, proxy_port))
      _(r.status).must_equal 1
      _(r.stdout).must_include "Could not read routes"
      _(r.stdout).must_include "Corrupted routes file (invalid JSON)"
      _(r.stdout).must_include "Summary: 1 failure"
    ensure
      rm_tmp(tmp)
    end

    it "warns when a route has an invalid port instead of crashing" do
      tmp = tmpdir("portless-doctor-bad-port-")
      proxy_port = get_free_port
      File.write(File.join(tmp, "routes.json"), JSON.generate([ { hostname: "bad.localhost", port: 99_999, pid: 0 } ]))
      r = run_cli(%w[doctor], env: doctor_env(tmp, proxy_port))
      _(r.status).must_equal 0
      _(r.stdout).must_include "Route bad.localhost has invalid port 99999."
      _(r.stdout).must_include "Summary: 0 failures"
      _(r.stderr).wont_include "Port should be"
    ensure
      rm_tmp(tmp)
    end

    it "does not report an alive stale PID file as healthy" do
      tmp = tmpdir("portless-doctor-pid-")
      proxy_port = get_free_port
      File.write(File.join(tmp, "proxy.port"), proxy_port.to_s)
      File.write(File.join(tmp, "proxy.pid"), Process.pid.to_s)
      r = run_cli(%w[doctor], env: { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_HTTPS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout).must_include "Proxy PID file points to PID #{Process.pid}, but no rb-portless proxy is responding on port #{proxy_port}."
      _(r.stdout).wont_include "Proxy PID file points to a running process"
      _(r.stdout).wont_include "Proxy PID file points to the responding proxy process"
    ensure
      rm_tmp(tmp)
    end

    it "reports a responding proxy and registered route" do
      tmp = tmpdir("portless-doctor-healthy-")
      app_server = http_server { [ 200, {}, "app" ] }
      proxy = start_mock_proxy(tmp, acknowledge_hosts_sync: false)
      File.write(File.join(tmp, "proxy.port"), proxy.port.to_s)
      File.write(File.join(tmp, "routes.json"), JSON.generate([ { hostname: "myapp.localhost", port: app_server.port, pid: 0 } ]))
      r = run_cli(%w[doctor], env: { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_HTTPS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout).must_include "Proxy is responding on port #{proxy.port}"
      _(r.stdout).must_include "Routes: 1 active route"
      _(r.stdout).must_include "Summary: 0 failures"
    ensure
      stop_child(proxy.child) if proxy
      app_server&.close
      rm_tmp(tmp)
    end

    it "does not bypass doctor when PORTLESS=0 is set" do
      r = run_cli(%w[doctor typo], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 2
      _(r.stderr).must_include "Unexpected argument"
      _(r.stderr).wont_include "ENOENT"
    end
  end

  describe "proxy" do
    it "shows proxy usage hint for bare 'proxy' command" do
      r = run_cli(%w[proxy])
      _(r.status).must_equal 0
      _(r.stdout).must_include "proxy start"
      _(r.stdout).must_include "proxy stop"
      _(r.stdout).must_include "--foreground"
    end

    it "exits 2 for unknown proxy subcommand" do
      r = run_cli(%w[proxy unknown])
      _(r.status).must_equal 2
      _(r.stderr).must_include 'Unknown proxy subcommand "unknown"'
    end

    it "rejects an unknown start flag before starting the proxy" do
      tmp = tmpdir("portless-proxy-args-")
      test_port = get_free_port
      r = run_cli(%w[proxy start --forground],
                  env: { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_PORT" => test_port.to_s, "PORTLESS_HTTPS" => "0" })
      _(r.status).must_equal 2
      _(r.stderr).must_include "Unknown flag"
      _(File.exist?(File.join(tmp, "proxy.pid"))).must_equal false
    ensure
      rm_tmp(tmp)
    end

    it "rejects an invalid --tld value as a usage error" do
      tmp = tmpdir("portless-proxy-tld-")
      r = run_cli(%w[proxy start --tld _bad], env: { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_HTTPS" => "0" })
      _(r.status).must_equal 2
      _(r.stderr).must_include "Invalid TLD"
      _(r.stderr).must_include "rb-portless proxy start --help"
      _(File.exist?(File.join(tmp, "proxy.pid"))).must_equal false
    ensure
      rm_tmp(tmp)
    end
  end

  describe "compose" do
    def docker_stub(dir, body)
      write_exe(File.join(dir, "docker"), body)
    end

    it "keeps container output on stdout and compose diagnostics on stderr" do
      routed = { name: "myapp", services: { web: { ports: [ { target: 3000, published: "3000" } ] } } }
      container_out = "web-1  | ready on http://0.0.0.0:3000\nweb-1  | GET / 200 4ms\n"
      result = run_compose_up_detached(model: routed, up_stdout: container_out)
      _(result[:status]).must_equal 0
      _(result[:stdout]).must_equal container_out
      _(result[:stderr]).must_include "rb-portless compose myapp"
      _(result[:stderr]).must_include "-> http://web.myapp.localhost:#{result[:proxy_port]}  (web:3000)"
    end

    it "sends the no-route notice and kept ports to stderr" do
      database_only = { name: "myapp", services: { db: { ports: [ { target: 5432, published: "5432" } ] } } }
      container_out = "db-1  | database system is ready\n"
      result = run_compose_up_detached(model: database_only, up_stdout: container_out)
      _(result[:status]).must_equal 0
      _(result[:stdout]).must_equal container_out
      _(result[:stderr]).must_include "db:5432 keeps host port 5432 (not HTTP)"
      _(result[:stderr]).must_include "No published HTTP ports found. Nothing to route."
    end

    it "keeps docker's exit code and stdout when a detached up fails" do
      routed = { name: "myapp", services: { web: { ports: [ { target: 3000, published: "3000" } ] } } }
      container_out = "web-1  | image pull failed\n"
      result = run_compose_up_detached(model: routed, up_stdout: container_out, up_exit: 3)
      _(result[:status]).must_equal 3
      _(result[:stdout]).must_equal container_out
      _(result[:stderr]).must_include "rb-portless compose myapp"
      _(result[:stderr]).wont_include "-> http"
    end

    it "prints help and exits 0 with no arguments" do
      r = run_cli(%w[compose])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless compose"
    end

    it "treats an unknown global flag without a subcommand as a usage error" do
      r = run_cli(%w[compose --bad])
      _(r.status).must_equal 2
      _(r.stderr).must_include 'Unknown flag "--bad" for rb-portless compose.'
    end

    it "prints compose help when --help is given with a bad flag" do
      [ %w[compose --help --bad], %w[compose --bad --help], %w[compose --help=true] ].each do |args|
        r = run_cli(args)
        _(r.status).must_equal 0
        _(r.stdout).must_include "rb-portless compose"
      end
    end

    it "rejects a bad global flag before a subcommand, even with child help, without running docker" do
      tmp = tmpdir("portless-compose-globals-")
      log = File.join(tmp, "docker.log")
      docker_stub(tmp, "#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$STUB_LOG\"\nexit 1\n")
      [ [], [ "--help" ], [ "-h" ] ].each do |extra|
        %w[up down ps config].each do |subcommand|
          r = run_cli([ "compose", "--bad", subcommand, *extra ],
                      env: { "PATH" => "#{tmp}:#{ENV['PATH']}", "STUB_LOG" => log, "PORTLESS" => nil })
          _(r.status).must_equal 2
          _(r.stdout).must_equal ""
          _(r.stderr).must_include 'Unknown flag "--bad" for rb-portless compose.'
          _(r.stderr).must_include "See: rb-portless compose --help"
        end
      end
      _(File.exist?(log)).must_equal false
    ensure
      rm_tmp(tmp)
    end

    it "keeps docker's exit code and arguments for the commands portless passes through" do
      tmp = tmpdir("portless-compose-passthrough-")
      log = File.join(tmp, "docker.log")
      docker_stub(tmp, "#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$STUB_LOG\"\necho \"docker $*\"\nexit 7\n")
      env = { "PATH" => "#{tmp}:#{ENV['PATH']}", "STUB_LOG" => log, "PORTLESS" => nil }
      [
        [ %w[compose ps --bad], "compose ps --bad" ],
        [ %w[compose -- logs -n 5], "compose logs -n 5" ],
        [ %w[compose -f compose.dev.yml config], "compose -f compose.dev.yml config" ],
        [ %w[compose -fcompose.dev.yml config], "compose -fcompose.dev.yml config" ],
        [ %w[compose -f=compose.dev.yml ps], "compose -f=compose.dev.yml ps" ],
        [ %w[compose -pdemo config], "compose -pdemo config" ],
        [ %w[compose -p=demo ps], "compose -p=demo ps" ],
        [ %w[compose --workdir /app logs], "compose --workdir /app logs" ],
        [ %w[compose --dry-run=true config], "compose --dry-run=true config" ],
        [ %w[compose --help=false ps], "compose --help=false ps" ],
        [ %w[compose -fcompose.dev.yml up --help], "compose -fcompose.dev.yml up --help" ],
        [ %w[compose -fcompose.dev.yml -- logs -n 5], "compose -fcompose.dev.yml logs -n 5" ]
      ].each do |args, expected|
        FileUtils.rm_f(log)
        r = run_cli(args, env: env)
        _(r.status).must_equal 7, args.inspect
        _(r.stdout).must_include "docker #{expected}"
        _(File.read(log).strip).must_equal expected
      end
    ensure
      rm_tmp(tmp)
    end

    it "leaves --ip= and --script= after a compose subcommand for docker" do
      tmp = tmpdir("portless-compose-run-flags-")
      log = File.join(tmp, "docker.log")
      docker_stub(tmp, "#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$STUB_LOG\"\necho \"docker $*\"\nexit 7\n")
      env = { "PATH" => "#{tmp}:#{ENV['PATH']}", "STUB_LOG" => log, "PORTLESS" => nil }
      [
        [ %w[compose run web node s.js --script=x], "compose run web node s.js --script=x" ],
        [ %w[compose run web node s.js --ip=127.0.0.1], "compose run web node s.js --ip=127.0.0.1" ]
      ].each do |args, expected|
        FileUtils.rm_f(log)
        r = run_cli(args, env: env)
        _(r.status).must_equal 7
        _(r.stdout).must_include "docker #{expected}"
        _(File.read(log).strip).must_equal expected
      end
    ensure
      rm_tmp(tmp)
    end

    it "keeps the wrapper's -- off the docker down command" do
      tmp = tmpdir("portless-compose-down-sep-")
      log = File.join(tmp, "docker.log")
      docker_stub(tmp, "#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$STUB_LOG\"\nexit 0\n")
      r = run_cli(%w[compose -f compose.yml -- down],
                  env: { "PATH" => "#{tmp}:#{ENV['PATH']}", "STUB_LOG" => log, "PORTLESS" => nil,
                         "PORTLESS_STATE_DIR" => File.join(tmp, "state") })
      _(r.status).must_equal 0
      calls = File.read(log).strip.split("\n")
      _(calls).must_include "compose -f compose.yml down"
      _(calls.any? { |c| c.include?("-- down") }).must_equal false
    ensure
      rm_tmp(tmp)
    end

    it "passes raw argv through when PORTLESS=0" do
      tmp = tmpdir("portless-compose-bypass-")
      log = File.join(tmp, "docker.log")
      docker_stub(tmp, "#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$STUB_LOG\"\necho \"docker $*\"\nexit 9\n")
      r = run_cli(%w[compose --bad -fcompose.yml up], env: { "PATH" => "#{tmp}:#{ENV['PATH']}", "STUB_LOG" => log, "PORTLESS" => "0" })
      _(r.status).must_equal 9
      _(r.stdout).must_include "docker compose --bad -fcompose.yml up"
      _(File.read(log).strip).must_equal "compose --bad -fcompose.yml up"
    ensure
      rm_tmp(tmp)
    end

    it "keeps the wrapper's -- off the docker command when PORTLESS=0" do
      tmp = tmpdir("portless-compose-bypass-sep-")
      log = File.join(tmp, "docker.log")
      docker_stub(tmp, "#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$STUB_LOG\"\necho \"docker $*\"\nexit 9\n")
      r = run_cli(%w[compose -- version], env: { "PATH" => "#{tmp}:#{ENV['PATH']}", "STUB_LOG" => log, "PORTLESS" => "0" })
      _(r.status).must_equal 9
      _(r.stdout).must_include "docker compose version"
      _(File.read(log).strip).must_equal "compose version"
    ensure
      rm_tmp(tmp)
    end
  end

  describe "prune" do
    it "rejects an unknown flag without changing routes.json" do
      tmp = tmpdir("portless-prune-args-")
      routes_path = File.join(tmp, "routes.json")
      routes = JSON.generate([ { hostname: "example.localhost", port: 3000, pid: 0 } ])
      File.write(routes_path, routes)
      r = run_cli(%w[prune --forc], env: { "PORTLESS_STATE_DIR" => tmp })
      _(r.status).must_equal 2
      _(r.stderr).must_include "Did you mean --force?"
      _(File.read(routes_path)).must_equal routes
    ensure
      rm_tmp(tmp)
    end
  end

  describe "service" do
    it "prints service help" do
      r = run_cli(%w[service --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless service"
      _(r.stdout).must_include "service install"
      _(r.stdout).must_include "service uninstall"
      _(r.stdout).must_include "service status"
    end

    it "still dispatches service help when PORTLESS=0" do
      r = run_cli(%w[service --help], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless service"
      _(r.stdout).must_include "service install"
    end
  end

  describe "error: no command provided" do
    it "exits 2 when only a name is given without a command" do
      r = run_cli(%w[myapp])
      _(r.status).must_equal 2
      _(r.stderr).must_include "No command provided"
    end

    it "suggests a command when the name is misspelled" do
      r = run_cli(%w[lsit])
      _(r.status).must_equal 2
      _(r.stderr).must_include "No command provided"
      _(r.stderr).must_include "rb-portless list"
    end

    it "suggests the command for a misspelled name followed by %s" do
      [
        [ "a help flag", %w[lsit --help] ],
        [ "an unknown flag", %w[lsit --json] ],
        [ "a leading flag", %w[--force lsit --help] ],
        [ "a leading sharing flag", %w[--ngrok lsit --help] ],
        [ "a leading app port", %w[--app-port 3000 lsit --help] ]
      ].each do |kase, args|
        r = run_cli(args)
        _(r.status).must_equal 2, kase
        _(r.stderr).must_include '"lsit" is not a rb-portless command. Did you mean:'
        _(r.stderr).must_include "rb-portless list"
        _(r.stderr).wont_include "Unknown flag"
      end
    end

    it "keeps a misspelled name as the app name when a command follows" do
      _(run_cli(%w[lis@t]).stderr).must_include "rb-portless list"

      r = run_cli(%w[lis@t echo test])
      _(r.status).must_equal 1
      _(r.stderr).must_include "Invalid hostname"
      _(r.stderr).wont_include "is not a rb-portless command"
    end

    it "does not suggest a command when --name sets the app name" do
      r = run_cli(%w[--name lsit])
      _(r.status).must_equal 2
      _(r.stderr).must_include "No command provided"
      _(r.stderr).wont_include "Did you mean"
    end
  end

  describe "PORTLESS=0 bypass" do
    it "runs reserved commands instead of spawning them" do
      tmp = tmpdir("portless-bypass-get-")
      r = run_cli(%w[get backend], env: { "PORTLESS" => "0", "PORTLESS_STATE_DIR" => tmp })
      _(r.status).must_equal 0
      _(r.stdout).must_include "backend.localhost"
    ensure
      rm_tmp(tmp)
    end

    it "runs command directly when PORTLESS=0 is set" do
      r = run_cli(%w[myapp echo hello], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "hello"
    end

    it "runs command directly when PORTLESS=skip is set" do
      r = run_cli(%w[myapp echo bypassed], env: { "PORTLESS" => "skip" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "bypassed"
    end

    it "does not bypass proxy commands when PORTLESS=0 is set" do
      tmp = tmpdir("portless-bypass-proxy-")
      proxy_port = get_free_port
      r = run_cli(%w[proxy stop], env: { "PORTLESS" => "0", "PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_STATE_DIR" => tmp })
      _(r.stderr).wont_include "ENOENT"
    ensure
      rm_tmp(tmp)
    end

    it "passes through exit code from bypassed command" do
      r = run_cli([ "myapp", RbConfig.ruby, "-e", "exit 42" ], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 42
    end
  end

  describe "PORTLESS=0 bypass with run subcommand" do
    it "runs command directly in run mode" do
      r = run_cli(%w[run echo hello], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "hello"
    end

    it "strips --force but passes child --force through" do
      r = run_cli(%w[run --force echo --force kept], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "--force kept"
    end

    it "passes -- separator through to child command" do
      r = run_cli(%w[run -- echo hello], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "hello"
    end
  end

  describe "--force positioning" do
    it "accepts --force before name (PORTLESS=0)" do
      r = run_cli(%w[--force myapp echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "ok"
    end

    it "accepts --force after name (PORTLESS=0)" do
      r = run_cli(%w[myapp --force echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "ok"
    end

    it "does not strip child command --force (PORTLESS=0)" do
      r = run_cli(%w[myapp echo --force kept], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "--force kept"
    end
  end

  describe "unknown flag detection" do
    it "rejects unknown flags before command" do
      r = run_cli(%w[--forec myapp echo test])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Unknown flag"
    end
  end

  describe "flag values" do
    it "accepts --flag=value for run and named mode" do
      run_mode = run_cli(%w[run --name=myapp echo ok], env: { "PORTLESS" => "0" })
      _(run_mode.status).must_equal 0
      _(run_mode.stdout.strip).must_equal "ok"

      named_mode = run_cli(%w[myapp --app-port=3000 echo ok], env: { "PORTLESS" => "0" })
      _(named_mode.status).must_equal 0
      _(named_mode.stdout.strip).must_equal "ok"
    end

    it "rejects a value on a boolean flag before running the child" do
      [ %w[run --force=false echo ran], %w[myapp --force=true echo ran] ].each do |args|
        r = run_cli(args, env: { "PORTLESS" => "0" })
        _(r.status).must_equal 2
        _(r.stderr).must_include "--force does not take a value."
        _(r.stdout).wont_include "ran"
      end
    end

    it "passes child flags after the command untouched" do
      r = run_cli([ "run", RbConfig.ruby, "-e", "puts ARGV.join(',')", "--", "--port", "3000", "--force" ],
                  env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "--port,3000,--force"
    end
  end

  describe "flag order" do
    it "prints run help before a later bad flag" do
      [ %w[run --help --bogus], %w[run --help --force=false], %w[run -h --app-port abc] ].each do |args|
        r = run_cli(args)
        _(r.status).must_equal 0
        _(r.stdout).must_include "rb-portless run"
        _(r.stderr).must_equal ""
      end
    end

    it "rejects a bad flag before a later --help" do
      unknown = run_cli(%w[run --bogus --help])
      _(unknown.status).must_equal 2
      _(unknown.stderr).must_include "Unknown flag"

      bad_value = run_cli(%w[run --app-port abc --help])
      _(bad_value.status).must_equal 2
      _(bad_value.stderr).must_include "Invalid app port"

      boolean_value = run_cli(%w[run --force=false --help])
      _(boolean_value.status).must_equal 2
      _(boolean_value.stderr).must_include "--force does not take a value."
    end

    it "checks every --app-port, not only the first" do
      [
        %w[run --app-port=3000 --app-port=abc echo ran],
        %w[myapp --app-port abc --app-port 3000 echo ran],
        %w[--app-port=3000 myapp --app-port=abc echo ran]
      ].each do |args|
        r = run_cli(args, env: { "PORTLESS" => "0" })
        _(r.status).must_equal 2
        _(r.stderr).must_include "Invalid app port"
        _(r.stdout).wont_include "ran"
      end
    end

    it "accepts repeated flags and runs the child" do
      r = run_cli(%w[run --force --force --name=a --name=b echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "ok"
    end
  end

  describe "invalid hostname" do
    it "exits 1 for hostname with invalid characters" do
      r = run_cli(%w[my@app echo test])
      _(r.status).must_equal 1
      _(r.stderr).must_include "Invalid hostname"
    end
  end

  describe "run subcommand dispatch" do
    it "exits 2 with 'No command provided' when no args follow run and no dev script" do
      tmp = tmpdir("portless-cli-run-")
      File.write(File.join(tmp, "package.json"), JSON.generate(name: "test-app"))
      r = run_cli(%w[run], cwd: tmp)
      _(r.status).must_equal 2
      _(r.stderr).must_include "No command provided"
    ensure
      rm_tmp(tmp)
    end

    it "does not dispatch 'list' as the global list command" do
      r = run_cli(%w[run list], env: { "PORTLESS" => "0" })
      _(r.stdout).wont_include "Active routes"
      _(r.stdout).wont_include "No active routes"
    end

    it "does not print version for run --version" do
      r = run_cli(%w[run --version])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Unknown flag"
    end

    it "prints run-specific help for run --help" do
      r = run_cli(%w[run --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless run"
      _(r.stdout).must_include "--force"
      _(r.stdout).must_include "--app-port"
    end

    it "prints run-specific help for run -h" do
      r = run_cli(%w[run -h])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless run"
    end

    it "accepts global --lan %s" do
      [ [ "before run", %w[--lan run] ], [ "in run options", %w[run --lan] ] ].each do |label, prefix|
        r = run_cli([ *prefix, RbConfig.ruby, "-e", "print ENV['PORTLESS_LAN']" ], env: { "PORTLESS" => "0" })
        _(r.status).must_equal 0, label
        _(r.stdout).must_equal "1"
      end
    end

    it "does not consume global-looking flags after the run command starts" do
      r = capture_bypassed_expo(%w[run --lan expo start --lan --ngrok --cloudflare])
      _(r[:status]).must_equal 0
      _(r[:args]).must_equal %w[start --lan --ngrok --cloudflare]
      _(r[:env]["PORTLESS_LAN"]).must_equal "1"
    end

    it "does not consume global-looking flags after a named command starts" do
      r = capture_bypassed_expo(%w[myapp --lan expo start --lan --ip 0.0.0.0])
      _(r[:status]).must_equal 0
      _(r[:args]).must_equal %w[start --lan --ip 0.0.0.0]
      _(r[:env]["PORTLESS_LAN"]).must_equal "1"
    end

    it "accepts global --lan after leading named-mode options" do
      r = run_cli([ "--app-port", "4567", "myapp", "--lan", RbConfig.ruby, "-e", "print ENV['PORTLESS_LAN']" ],
                  env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout).must_equal "1"
    end

    it "does not consume global-looking flags after an explicit --name command starts" do
      r = capture_bypassed_expo(%w[--name myapp --lan expo start --lan --funnel])
      _(r[:status]).must_equal 0
      _(r[:args]).must_equal %w[start --lan --funnel]
      _(r[:env]["PORTLESS_LAN"]).must_equal "1"
    end
  end

  describe "named mode help" do
    it "prints run help for named mode %s without running anything" do
      [ "--help", "-h" ].each do |flag|
        tmp = tmpdir("portless-named-help-")
        bin = File.join(tmp, "bin")
        home = File.join(tmp, "home")
        state = File.join(tmp, "state")
        [ bin, home, state ].each { |d| Dir.mkdir(d) }
        r = run_cli([ "myapp", flag ], cwd: tmp, env: { "PATH" => bin, "HOME" => home, "PORTLESS_STATE_DIR" => state, "PORTLESS" => nil })
        _(r.status).must_equal 0
        _(r.stdout).must_equal run_cli(%w[run --help], env: { "PORTLESS" => nil }).stdout
        _(r.stderr).must_equal ""
        _(Dir.children(state)).must_equal []
      ensure
        rm_tmp(tmp)
      end
    end

    it "passes %s after the named command to the child" do
      [ "--help", "-h" ].each do |flag|
        r = capture_bypassed_expo([ "myapp", "expo", "start", flag ])
        _(r[:status]).must_equal 0
        _(r[:args]).must_equal [ "start", flag ]
      end
    end
  end

  describe "--app-port flag" do
    it "passes --app-port through in bypass mode (PORTLESS=0)" do
      r = run_cli(%w[run --app-port 4567 echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "ok"
    end

    it "rejects invalid --app-port value" do
      r = run_cli(%w[run --app-port abc echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 2
      _(r.stderr).must_include "Invalid app port"
    end

    it "rejects --app-port without a value" do
      r = run_cli(%w[run --app-port], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 2
      _(r.stderr).must_include "--app-port requires"
    end

    it "accepts --app-port in named mode (PORTLESS=0)" do
      r = run_cli(%w[myapp --app-port 3000 echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "ok"
    end
  end

  describe "alias subcommand" do
    it "prints help with --help" do
      r = run_cli(%w[alias --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless alias"
      _(r.stdout).must_include "--remove"
      _(r.stdout).must_include "--upstream"
      _(r.stdout).must_include "HTTP/1.1"
    end

    it "prints help with -h" do
      r = run_cli(%w[alias -h])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless alias"
    end

    it "exits 2 with usage when no args given" do
      r = run_cli(%w[alias])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Missing alias name"
    end

    it "exits 2 with usage when only name is given" do
      r = run_cli(%w[alias mydb])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Missing port"
    end

    it "exits 2 for invalid port" do
      r = run_cli(%w[alias mydb notaport])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Invalid port"
    end

    it "rejects upstream %s before discovering state" do
      [
        [ "missing value", [ "--upstream" ], "--upstream requires a value" ],
        [ "flag used as value", [ "--upstream", "--help" ], "--upstream requires a value" ],
        [ "bare hostname", [ "--upstream", "api.internal" ], "Invalid --upstream value" ],
        [ "path", [ "--upstream", "https://api.internal/path" ], "Invalid --upstream value" ],
        [ "query", [ "--upstream", "https://api.internal?key=value" ], "Invalid --upstream value" ],
        [ "fragment", [ "--upstream", "https://api.internal#fragment" ], "Invalid --upstream value" ],
        [ "credentials", [ "--upstream", "https://user@api.internal" ], "Invalid --upstream value" ],
        [ "invalid port", [ "--upstream", "http://api.internal:65536" ], "Invalid --upstream value" ],
        [ "duplicate option", [ "--upstream", "https", "--upstream", "http://api.internal" ], "may be specified only once" ]
      ].each do |kase, args, message|
        tmp = tmpdir("portless-alias-upstream-")
        state_dir = File.join(tmp, "state")
        result = run_cli([ "alias", "api", "8080", *args ], env: { "PORTLESS_STATE_DIR" => state_dir })
        _(result.status).must_equal 2, kase
        _(result.stderr).must_include message
        _(File.exist?(state_dir)).must_equal false
      ensure
        rm_tmp(tmp)
      end
    end

    it "accepts --upstream=value like any other value flag" do
      tmp = tmpdir("portless-alias-upstream-eq-")
      r = run_cli(%w[alias api 8080 --upstream=http://api.internal --tld localhost],
                  env: { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_SYNC_HOSTS" => "0" })
      _(r.status).must_equal 0
      routes = JSON.parse(File.read(File.join(tmp, "routes.json")))
      _(routes.find { |route| route["hostname"] == "api.localhost" }["upstream"]).must_equal({ "tls" => false, "host" => "api.internal" })
    ensure
      rm_tmp(tmp)
    end

    it "exits 2 without registering a route for a port with trailing text" do
      tmp = tmpdir("portless-alias-port-")
      r = run_cli(%w[alias mydb 192.168.1.1:8123], env: { "PORTLESS_STATE_DIR" => tmp })
      _(r.status).must_equal 2
      _(r.stderr).must_include 'Invalid port "192.168.1.1:8123"'
      _(File.exist?(File.join(tmp, "routes.json"))).must_equal false
    ensure
      rm_tmp(tmp)
    end

    it "exits 2 for invalid proxy stop arguments" do
      r = run_cli(%w[proxy stop -p 8123abc])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Invalid port number: 8123abc"

      [ [ "-p" ], [ "--port" ], [ "--port", "" ], [ "extra" ] ].each do |args|
        invalid = run_cli([ "proxy", "stop", *args ])
        _(invalid.status).must_equal 2, args.inspect
        _(invalid.stderr).must_include "Error:"
        _(invalid.stderr).wont_include "Proxy is not running"
      end
    end

    it "exits 2 when --remove has no name" do
      r = run_cli(%w[alias --remove])
      _(r.status).must_equal 2
      _(r.stderr).must_include "--remove requires a value"
    end

    it "rejects a repeated --remove" do
      r = run_cli(%w[alias --remove a --remove b])
      _(r.status).must_equal 2
      _(r.stderr).must_include "--remove may be specified only once."
    end

    it "prints help without registering a route when --help follows the arguments" do
      tmp = tmpdir("portless-alias-help-")
      r = run_cli(%w[alias mydb 5432 --help], env: { "PORTLESS_STATE_DIR" => tmp })
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless alias"
      _(File.exist?(File.join(tmp, "routes.json"))).must_equal false
    ensure
      rm_tmp(tmp)
    end

    it "exits 2 on unknown flags without registering a route" do
      tmp = tmpdir("portless-alias-flag-")
      [ [ "--frce", 'Unknown flag "--frce"' ], [ "--remove", "--remove requires a value" ] ].each do |flag, message|
        r = run_cli([ "alias", "mydb", "5432", flag ], env: { "PORTLESS_STATE_DIR" => tmp })
        _(r.status).must_equal 2
        _(r.stderr).must_include message
      end
      _(File.exist?(File.join(tmp, "routes.json"))).must_equal false
    ensure
      rm_tmp(tmp)
    end

    it "registers and removes only the selected configured TLDs" do
      tmp = tmpdir("portless-alias-tld-")
      routes_path = File.join(tmp, "routes.json")
      env = { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_SYNC_HOSTS" => "0" }
      routes = -> { JSON.parse(File.read(routes_path)) }
      hostnames = -> { routes.().map { |r| r["hostname"] } }
      upstream_of = ->(host) { routes.().find { |r| r["hostname"] == host }["upstream"] }
      File.write(File.join(tmp, "proxy.tlds"), "localhost\ntest\ndev\n")
      add = run_cli(%w[alias mydb 5432 --upstream https://api.internal:8443 --tld localhost,test --tld test], env: env)
      _(add.status).must_equal 0
      _(hostnames.().sort).must_equal %w[mydb.localhost mydb.test]
      _(upstream_of.("mydb.localhost")).must_equal({ "tls" => true, "host" => "api.internal:8443" })
      tls_only = run_cli(%w[alias mytls 7443 --upstream https --tld localhost], env: env)
      plain = run_cli(%w[alias myplain 8080 --upstream http://api.internal --tld localhost], env: env)
      _(tls_only.status).must_equal 0
      _(plain.status).must_equal 0
      _(upstream_of.("mytls.localhost")).must_equal({ "tls" => true })
      _(upstream_of.("myplain.localhost")).must_equal({ "tls" => false, "host" => "api.internal" })
      remove = run_cli(%w[alias --remove mydb --tld test], env: env)
      _(remove.status).must_equal 0
      _(hostnames.().sort).must_equal %w[mydb.localhost myplain.localhost mytls.localhost]

      [
        [ [ "--tld", "test", "--tld", " " ], 2, "--tld requires a TLD value" ],
        [ %w[--tld unknown], 1, 'TLD "unknown" is not configured (localhost, test, dev).' ],
        [ %w[--tld], 2, "--tld requires a value" ]
      ].each do |args, status, message|
        invalid = run_cli([ "alias", "mydb", "5432", *args ], env: env)
        _(invalid.status).must_equal status, args.inspect
        _(invalid.stderr).must_include message
        _(hostnames.().sort).must_equal %w[mydb.localhost myplain.localhost mytls.localhost]
      end

      force_remove = run_cli(%w[alias --remove mydb --force], env: env)
      _(force_remove.status).must_equal 2
      _(force_remove.stderr).must_include "--force cannot be used with --remove"
      _(hostnames.().sort).must_equal %w[mydb.localhost myplain.localhost mytls.localhost]
    ensure
      rm_tmp(tmp)
    end

    it "keeps live app routes when removing an alias across TLDs" do
      tmp = tmpdir("portless-alias-remove-live-")
      routes_path = File.join(tmp, "routes.json")
      env = { "PORTLESS_STATE_DIR" => tmp, "PORTLESS_SYNC_HOSTS" => "0" }
      routes = -> { JSON.parse(File.read(routes_path)) }
      File.write(File.join(tmp, "proxy.tlds"), "localhost\ntest\n")
      File.write(routes_path, JSON.generate([ { hostname: "mydb.localhost", port: 4101, pid: Process.pid },
                                              { hostname: "mydb.test", port: 4102, pid: 0 } ]))
      live = [ { "hostname" => "mydb.localhost", "port" => 4101, "pid" => Process.pid } ]

      removed = run_cli(%w[alias --remove mydb], env: env)
      _(removed.status).must_equal 0
      _(removed.stdout).must_include "mydb.test"
      _(removed.stdout).wont_include "mydb.localhost"
      _(routes.()).must_equal live

      repeated = run_cli(%w[alias --remove mydb], env: env)
      _(repeated.status).must_equal 1
      _(repeated.stderr).must_include "No alias found"

      live_tld = run_cli(%w[alias --remove mydb --tld localhost], env: env)
      _(live_tld.status).must_equal 1
      _(live_tld.stderr).must_include 'No alias found for "mydb.localhost"'
      _(routes.()).must_equal live
    ensure
      rm_tmp(tmp)
    end
  end

  describe "hosts subcommand" do
    it "prints help with --help" do
      r = run_cli(%w[hosts --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless hosts"
      _(r.stdout).must_include "sync"
      _(r.stdout).must_include "clean"
    end

    it "prints help with -h" do
      r = run_cli(%w[hosts -h])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless hosts"
    end

    it "shows usage for bare 'hosts' without subcommand" do
      r = run_cli(%w[hosts])
      _(r.status).must_equal 0
      _(r.stdout).must_include "sync"
      _(r.stdout).must_include "clean"
    end

    it "rejects unknown hosts subcommand" do
      r = run_cli(%w[hosts typo])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Unknown hosts subcommand"
    end

    describe "sync safety" do
      before do
        @tmp_dir = tmpdir("portless-hosts-cli-test-")
        File.write(File.join(@tmp_dir, "routes.json"), "[]")
      end

      after do
        rm_tmp(@tmp_dir)
      end


      it "removes stale entries for an empty routes file without changing unrelated entries" do
        r = run_with_hosts_file_mock(%w[hosts sync], content: UpstreamCli::STALE_HOSTS, state_dir: @tmp_dir)
        _(r.status).must_equal 0
        _(r.stdout).must_include "No stale rb-portless entries remain"
        _(r.capture["writes"].length).must_equal 1
        _(r.capture["content"]).must_include "127.0.0.1 localhost"
        _(r.capture["content"]).must_include "192.0.2.10 custom.test"
        _(r.capture["content"]).wont_include "portless-start"
        _(r.capture["content"]).wont_include "stale.test"
      end

      it "refuses to publish hostnames from a state directory other users can write to" do
        File.write(File.join(@tmp_dir, "routes.json"), JSON.generate([ { hostname: "planted.test", port: 1, pid: 0 } ]))
        File.chmod(0o777, @tmp_dir)
        r = run_with_hosts_file_mock(%w[hosts sync], content: UpstreamCli::STALE_HOSTS, state_dir: @tmp_dir)
        _(r.status).must_equal 1
        _(r.stderr).must_include "Cannot sync hosts from routes recorded in #{@tmp_dir}"
        _(r.capture["writes"].length).must_equal 0
        _(r.capture["sudoCalls"]).must_equal []
      ensure
        File.chmod(0o755, @tmp_dir)
      end

      it "succeeds without writing when an empty routes file meets a readable empty hosts file" do
        r = run_with_hosts_file_mock(%w[hosts sync], content: "", state_dir: @tmp_dir)
        _(r.status).must_equal 0
        _(r.stdout).must_include "No stale rb-portless entries remain"
        _(r.capture["writes"]).must_equal []
      end

      it "uses the normal failure path without writing after an initial hosts read error" do
        r = run_with_hosts_file_mock(%w[hosts sync], content: UpstreamCli::STALE_HOSTS, read_mode: "initial-error", state_dir: @tmp_dir, uid: 0)
        _(r.status).must_equal 1
        _(r.stderr).must_include "Failed to update"
        _(r.capture["writes"]).must_equal []
        _(r.capture["sudo"]).must_be_nil
      end

      it "uses the normal failure path when post-write verification cannot read" do
        r = run_with_hosts_file_mock(%w[hosts sync], content: UpstreamCli::STALE_HOSTS, read_mode: "verification-error",
                                                     state_dir: @tmp_dir, uid: 0)
        _(r.status).must_equal 1
        _(r.stderr).must_include "Failed to update"
        _(r.capture["writes"].length).must_equal 1
      end

      it "retries a failed initial read through the existing sudo path" do
        r = run_with_hosts_file_mock(%w[hosts sync], content: UpstreamCli::STALE_HOSTS, read_mode: "initial-error", state_dir: @tmp_dir,
                                                     uid: 1000, sudo_status: 0)
        _(r.status).must_equal 0
        _(r.stdout).must_include "Requesting sudo"
        _(r.capture["writes"]).must_equal []
        _(r.capture["sudo"]["command"]).must_equal "sudo"
        _(r.capture["sudo"]["args"]).must_include "hosts"
        _(r.capture["sudo"]["args"]).must_include "sync"
      end

      it "uses the normal failure path for a cleanup read error" do
        r = run_with_hosts_file_mock(%w[hosts clean], content: UpstreamCli::STALE_HOSTS, read_mode: "initial-error", state_dir: @tmp_dir, uid: 0)
        _(r.status).must_equal 1
        _(r.stderr).must_include "Failed to update"
        _(r.capture["writes"]).must_equal []
      end
    end
  end

  describe "clean subcommand" do
    before do
      @tmp_dir = tmpdir("portless-clean-")
      @state_dir = File.join(@tmp_dir, "state")
      @home = File.join(@tmp_dir, "home")
      Dir.mkdir(@state_dir)
      Dir.mkdir(@home)
    end

    after do
      File.chmod(0o700, @state_dir) rescue nil
      rm_tmp(@tmp_dir)
    end

    def linux_only!
      skip "Linux-only upstream test (it.runIf linux)" unless RUBY_PLATFORM.include?("linux")
    end

    def write_state(name, content) = File.write(File.join(@state_dir, name), content)
    def read_state(name) = File.read(File.join(@state_dir, name))
    def state?(name) = File.exist?(File.join(@state_dir, name))
    def base_extra(port = get_free_port) = { "HOME" => @home, "PORTLESS_PORT" => port.to_s, "PORTLESS_HTTPS" => "0" }

    def spawn_bystander = spawn_bg([ RbConfig.ruby, "-e", "sleep" ], out: false)

    it "clean --yes removes a leftover routes.lock directory" do
      tmp = tmpdir("portless-clean-lock-")
      state_dir = File.join(tmp, "state")
      home = File.join(tmp, "home")
      bin = File.join(tmp, "bin")
      hosts_writable = File.writable?("/etc/hosts")
      skip if File.exist?("/tmp/portless") || hosts_writable || File.read("/etc/hosts").include?("# rb-portless-start")
      FileUtils.mkdir_p(File.join(state_dir, "routes.lock"))
      Dir.mkdir(home)
      Dir.mkdir(bin)
      File.symlink(RbConfig.ruby, File.join(bin, "ruby"))
      File.write(File.join(state_dir, "routes.json"), "not json")
      result = run_cli(%w[clean --yes], env: { "HOME" => home, "PORTLESS_STATE_DIR" => state_dir, "PATH" => bin,
                                               "PORTLESS_PORT" => get_free_port.to_s, "PORTLESS_HTTPS" => "0" })
      _(result.status).must_equal 1
      _(result.stderr).must_include "Could not read routes for tunnel cleanup"
      _(File.exist?(File.join(state_dir, "routes.lock"))).must_equal false
      _(File.exist?(File.join(state_dir, "routes.json"))).must_equal false
    ensure
      rm_tmp(tmp)
    end

    it "reports a failure when a tailscale share cannot be removed" do
      bin = File.join(@tmp_dir, "bin")
      Dir.mkdir(bin)
      write_exe(File.join(bin, "tailscale"), "#!/bin/sh\necho \"permission denied\" >&2\nexit 1\n")
      write_state("routes.json", JSON.generate([ { hostname: "app.localhost", port: 4001, pid: 0, tailscaleHttpsPort: 8443 } ]))
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 1000, sudo_status: 0,
                                                         extra_env: base_extra.merge("PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV['PATH']}"))
      _(result.status).must_equal 1, result.stderr
      _(result.stderr).must_include "Failed to remove tailscale serve on port 8443"
      _(result.stderr).must_include "Clean finished with 1 problem(s)."
    end

    it "waits for the proxy listener to close before reporting success" do
      proxy = start_mock_proxy(@state_dir, sigterm_delay_ms: 300)
      write_state("proxy.pid", proxy.child.pid.to_s)
      write_state("proxy.port", proxy.port.to_s)
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 0, extra_env: base_extra(proxy.port))
      _(result.status).must_equal 0, result.stderr
      _(result.stdout).must_include "Proxy stopped."
      _(result.stdout).wont_include "still running"
    ensure
      stop_child(proxy.child) if proxy
    end

    it "retries only the failed CA, state-file, and hosts steps through sudo" do
      linux_only!
      write_state("ca.pem", "certificate")
      write_state("ca-key.pem", "private key")
      write_state("ca.trust-refresh-pending", "1")
      write_state("routes.json", "[]")
      write_state("keep.txt", "keep")
      result = run_with_hosts_file_mock(%w[clean --yes], content: "# rb-portless-start\n127.0.0.1 stale.localhost\n# rb-portless-end\n",
                                                         write_mode: "privileged", fail_privileged_cleanup: true,
                                                         state_dir: @state_dir, uid: 1000, sudo_status: 1, extra_env: base_extra)
      _(result.status).must_equal 1
      _(result.capture["sudoCalls"].length).must_equal 1
      sudo_args = result.capture["sudoCalls"][0]["args"]
      _(sudo_args).must_include "PORTLESS_INTERNAL_CLEAN_STEPS=ca,files,hosts"
      _(sudo_args).must_include "PORTLESS_INTERNAL_CLEAN_DIRS=#{JSON.generate([ @state_dir ])}"
      _(sudo_args).wont_include "PORTLESS_INTERNAL_CLEAN_PRESERVE_PROXY=1"
      _(sudo_args.any? { |a| a.start_with?("PORTLESS_STATE_DIR=") }).must_equal false
      _(sudo_args.last(2)).must_equal %w[clean --yes]
      _(sudo_args.join(" ")).wont_include "service"
      _(sudo_args.join(" ")).wont_include "prune"
      _(sudo_args.join(" ")).wont_include "--force"
    end

    it "runs the elevated allowlist without calling sudo again" do
      linux_only!
      write_state("ca.pem", "certificate")
      write_state("ca-key.pem", "private key")
      write_state("ca.trust-refresh-pending", "1")
      write_state("routes.json", "[]")
      write_state("keep.txt", "keep")
      result = run_with_hosts_file_mock(%w[clean --yes], content: "# rb-portless-start\n127.0.0.1 stale.localhost\n# rb-portless-end\n",
                                                         write_mode: "privileged", fail_privileged_cleanup: true,
                                                         state_dir: @state_dir, uid: 1000,
                                                         extra_env: base_extra.merge("PORTLESS_INTERNAL_CLEAN_STEPS" => "ca,files,hosts",
                                                                                     "PORTLESS_INTERNAL_CLEAN_DIRS" => JSON.generate([ @state_dir ])))
      _(result.status).must_equal 0, result.stderr
      _(result.capture["sudoCalls"]).must_equal []
      _(state?("routes.json")).must_equal false
      _(state?("ca.pem")).must_equal false
      _(state?("ca-key.pem")).must_equal false
      _(read_state("keep.txt")).must_equal "keep"
      _(result.capture["content"]).wont_include "portless-start"
    end

    it "preserves pending CA identity in files-only elevated cleanup" do
      tmp = tmpdir("portless-clean-files-only-")
      state_dir = File.join(tmp, "state")
      Dir.mkdir(state_dir)
      File.write(File.join(state_dir, "ca-key.pem"), "private key")
      File.write(File.join(state_dir, "ca.trust-refresh-pending"), "1")
      File.write(File.join(state_dir, "routes.json"), "[]")
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: state_dir, uid: 0,
                                                         extra_env: { "HOME" => tmp, "PORTLESS_INTERNAL_CLEAN_STEPS" => "files",
                                                                      "PORTLESS_INTERNAL_CLEAN_DIRS" => JSON.generate([ state_dir ]) })
      _(result.status).must_equal 0, result.stderr
      _(File.exist?(File.join(state_dir, "routes.json"))).must_equal false
      _(File.read(File.join(state_dir, "ca-key.pem"))).must_equal "private key"
      _(File.read(File.join(state_dir, "ca.trust-refresh-pending"))).must_equal "1"
    ensure
      rm_tmp(tmp)
    end

    it "requests CA and files retry when an approved state dir cannot be inspected" do
      write_state("ca.pem", "certificate")
      write_state("ca-key.pem", "private key")
      write_state("ca.trust-refresh-pending", "1")
      write_state("routes.json", "[]")
      File.chmod(0o000, @state_dir)
      readable = begin
        Dir.children(@state_dir)
        true
      rescue SystemCallError
        false
      end
      if readable
        File.chmod(0o700, @state_dir)
        skip
      end
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 1000, sudo_status: 1,
                                                         extra_env: base_extra)
      _(result.status).must_equal 1
      _(result.capture["sudoCalls"].length).must_equal 1
      _(result.capture["sudoCalls"][0]["args"]).must_include "PORTLESS_INTERNAL_CLEAN_STEPS=ca,files"

      File.chmod(0o700, @state_dir)
      _(read_state("ca.pem")).must_equal "certificate"
      _(read_state("ca-key.pem")).must_equal "private key"
      _(read_state("ca.trust-refresh-pending")).must_equal "1"
      _(read_state("routes.json")).must_equal "[]"
    ensure
      File.chmod(0o700, @state_dir)
    end

    it "retries file cleanup when CA trust removal is the only failure" do
      linux_only!
      write_state("ca.pem", "certificate")
      write_state("ca-key.pem", "private key")
      write_state("ca.trust-refresh-pending", "1")
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", fail_privileged_cleanup: true, state_dir: @state_dir,
                                                         uid: 1000, sudo_status: 1, extra_env: base_extra)
      _(result.status).must_equal 1
      _(result.capture["sudoCalls"].length).must_equal 1
      _(result.capture["sudoCalls"][0]["args"]).must_include "PORTLESS_INTERNAL_CLEAN_STEPS=ca,files"
    end

    it "keeps CA identity when a failed sudo refresh leaves the retry marker" do
      linux_only!
      write_state("ca.pem", "certificate")
      write_state("ca-key.pem", "private key")
      write_state("ca.trust-refresh-pending", "1")
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", fail_ca_only: true, state_dir: @state_dir,
                                                         uid: 1000, sudo_status: 1, extra_env: base_extra)
      _(result.status).must_equal 1
      _(result.capture["sudoCalls"].length).must_equal 1
      _(result.stderr).must_include "Could not remove CA from trust store"
      _(result.stderr).must_include "Retained CA identity files"
      _(read_state("ca.pem")).must_equal "certificate"
      _(read_state("ca-key.pem")).must_equal "private key"
      _(read_state("ca.trust-refresh-pending")).must_equal "1"
    end

    it "removes preserved CA identity after a successful elevated trust retry" do
      linux_only!
      write_state("ca.pem", "certificate")
      write_state("ca-key.pem", "private key")
      write_state("ca.trust-refresh-pending", "1")
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", fail_privileged_cleanup: true, sudo_runs_command: true,
                                                         state_dir: @state_dir, uid: 1000, extra_env: base_extra)
      _(result.status).must_equal 0, result.stdout + result.stderr
      _(result.capture["sudoCalls"].length).must_equal 1
      _(state?("ca.pem")).must_equal false
      _(state?("ca-key.pem")).must_equal false
      _(state?("ca.trust-refresh-pending")).must_equal false
    end

    it "requires confirmation before the internal cleanup allowlist runs" do
      tmp = tmpdir("portless-clean-env-confirm-")
      state_dir = File.join(tmp, "state")
      Dir.mkdir(state_dir)
      File.write(File.join(state_dir, "routes.json"), "[]")
      result = run_with_hosts_file_mock(%w[clean], content: "", state_dir: state_dir, uid: 0,
                                                   extra_env: { "PORTLESS_INTERNAL_CLEAN_STEPS" => "files",
                                                                "PORTLESS_INTERNAL_CLEAN_DIRS" => JSON.generate([ state_dir ]) })
      _(result.status).must_equal 2
      _(result.stderr).must_include "rb-portless clean --yes"
      _(File.read(File.join(state_dir, "routes.json"))).must_equal "[]"
    ensure
      rm_tmp(tmp)
    end

    it "keeps proxy identity when the proxy cannot be stopped" do
      linux_only!
      proxy = start_mock_proxy(@state_dir, sigterm_delay_ms: 6000)
      write_state("proxy.pid", proxy.child.pid.to_s)
      write_state("proxy.port", proxy.port.to_s)
      write_state("proxy.tls", "1")
      write_state("proxy.custom-cert", "1")
      write_state("proxy.tld", "localhost")
      write_state("proxy.tlds", "localhost\ntest\n")
      write_state("proxy.lan", "192.0.2.10")
      write_state("routes.json", "[]")
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", fail_privileged_cleanup: true, state_dir: @state_dir,
                                                         uid: 1000, sudo_status: 0, extra_env: base_extra(proxy.port))
      _(result.status).must_equal 1
      _(result.stderr).must_include "Proxy did not stop within"
      _(read_state("proxy.pid")).must_equal proxy.child.pid.to_s
      _(read_state("proxy.port")).must_equal proxy.port.to_s
      %w[proxy.tls proxy.custom-cert proxy.tld proxy.tlds proxy.lan].each { |m| _(state?(m)).must_equal true }
      _(result.capture["sudoCalls"].length).must_equal 1
      sudo_args = result.capture["sudoCalls"][0]["args"]
      _(sudo_args).must_include "PORTLESS_INTERNAL_CLEAN_STEPS=files"
      _(sudo_args).must_include "PORTLESS_INTERNAL_CLEAN_PRESERVE_PROXY=1"
    ensure
      if proxy && !proxy.child.exited?
        proxy.child.kill("KILL")
        proxy.child.wait
      end
    end

    %w[recorded legacy].each do |identity|
      it "keeps state and CA trust when a live proxy does not answer the probe (#{identity} identity)" do
        proxy = start_mock_proxy(@state_dir, portless_header: false)
        pid = proxy.child.pid
        start_time_path = File.join(@state_dir, "proxy.start")
        write_state("proxy.pid", pid.to_s)
        write_state("proxy.port", proxy.port.to_s)
        if identity == "recorded"
          start_time = get_process_start_time(pid)
          _(start_time).wont_be_nil
          File.write(start_time_path, start_time)
        end
        write_state("ca.pem", "certificate")
        write_state("ca-key.pem", "private key")
        Dir.mkdir(File.join(@state_dir, "host-certs"))
        File.write(File.join(@state_dir, "host-certs", "app.pem"), "certificate")

        result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 1000, sudo_status: 1,
                                                           extra_env: base_extra(proxy.port))
        _(result.status).must_equal 1, result.stdout + result.stderr
        _(result.stderr).must_include "Proxy PID #{pid} is not responding on port #{proxy.port}"
        _(result.stderr).must_include "Kept the CA in the trust store"
        _(result.stderr).wont_include "kill -CONT"
        _(result.capture["sudoCalls"]).must_equal []
        %w[proxy.pid proxy.port ca.pem ca-key.pem].each { |f| _(state?(f)).must_equal true, f }
        _(File.exist?(start_time_path)).must_equal(identity == "recorded")
        _(File.exist?(File.join(@state_dir, "host-certs", "app.pem"))).must_equal true
        _(alive_pid?(pid)).must_equal true
      ensure
        stop_child(proxy.child) if proxy
      end
    end

    %w[available unavailable].each do |socket_lookup|
      it "keeps state and CA trust when a suspended proxy stops answering (#{socket_lookup} socket lookup)" do
        proxy = start_mock_proxy(@state_dir)
        pid = proxy.child.pid
        write_state("proxy.pid", pid.to_s)
        write_state("proxy.port", proxy.port.to_s)
        write_state("ca.pem", "certificate")
        write_state("ca-key.pem", "private key")
        Dir.mkdir(File.join(@state_dir, "host-certs"))
        File.write(File.join(@state_dir, "host-certs", "app.pem"), "certificate")
        Process.kill("STOP", pid)

        extra = base_extra(proxy.port)
        extra["PATH"] = failing_lsof_path(@tmp_dir) if socket_lookup == "unavailable"
        result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 1000, sudo_status: 1,
                                                           extra_env: extra)
        _(result.status).must_equal 1
        _(result.stderr).must_include(socket_lookup == "unavailable" ?
          "Could not verify that PID #{pid} is the proxy on port #{proxy.port}" :
          "Proxy PID #{pid} is not responding on port #{proxy.port}")
        _(result.stderr).must_include "kill -CONT #{pid}"
        _(result.stderr).must_include "Kept the CA in the trust store"
        _(result.capture["sudoCalls"]).must_equal []
        %w[proxy.pid proxy.port ca.pem ca-key.pem].each { |f| _(state?(f)).must_equal true, f }
        _(File.exist?(File.join(@state_dir, "host-certs", "app.pem"))).must_equal true
        _(alive_pid?(pid)).must_equal true
      ensure
        if proxy && !proxy.child.exited?
          Process.kill("CONT", pid) rescue nil
          proxy.child.kill("KILL")
          proxy.child.wait
        end
      end
    end

    [ "a state directory others can write to", "a mismatched start time" ].each do |planted|
      it "never signals a recorded PID that is not the answering proxy (#{planted})" do
        proxy = start_mock_proxy(@state_dir)
        bystander = spawn_bystander
        pid = bystander.pid
        write_state("proxy.pid", pid.to_s)
        write_state("proxy.port", proxy.port.to_s)
        if planted == "a mismatched start time"
          write_state("proxy.start", "not the start time")
        else
          sleep 0.1 until get_process_start_time(pid)
          write_state("proxy.start", get_process_start_time(pid))
          File.chmod(0o777, @state_dir)
        end

        result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 1000, sudo_status: 1,
                                                           extra_env: base_extra(proxy.port))
        _(result.status).must_equal 1, result.stdout + result.stderr
        _(result.stderr).must_include(planted == "a mismatched start time" ?
          "PID #{pid} in #{File.join(@state_dir, 'proxy.pid')} is not the proxy answering on port #{proxy.port}" :
          "Cannot stop the proxy recorded in #{@state_dir}: other users can write to it")
        _(alive_pid?(pid)).must_equal true
        _(alive_pid?(proxy.child.pid)).must_equal true
        _(state?("proxy.pid")).must_equal true
      ensure
        File.chmod(0o755, @state_dir)
        bystander&.kill
        stop_child(proxy.child) if proxy
      end
    end

    it "removes stale proxy state for a recycled PID without signaling it" do
      port = get_free_port
      unrelated = spawn_bystander
      pid = unrelated.pid
      sleep 0.2
      write_state("proxy.pid", pid.to_s)
      write_state("proxy.port", port.to_s)
      write_state("proxy.tls", "1")
      write_state("proxy.lan", "192.0.2.10")

      result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 1000, sudo_status: 1,
                                                         extra_env: base_extra(port))
      _(result.status).must_equal 0, result.stderr
      _(result.stdout).must_include "PID #{pid} is not a proxy listening on port #{port}"
      _(result.stdout).must_include "Removed stale proxy state"
      _(result.stderr).wont_include "kill -CONT"
      _(result.capture["sudoCalls"]).must_equal []
      %w[proxy.pid proxy.port].each { |f| _(state?(f)).must_equal false }
      _(alive_pid?(pid)).must_equal true
    ensure
      unrelated&.kill
    end

    it "removes stale proxy state when the recorded start time belongs to another process" do
      port = get_free_port
      unrelated = spawn_bystander
      pid = unrelated.pid
      sleep 0.2
      _(get_process_start_time(pid)).wont_equal "Thu Jan  1 00:00:00 1970"
      write_state("proxy.pid", pid.to_s)
      write_state("proxy.port", port.to_s)
      write_state("proxy.start", "Thu Jan  1 00:00:00 1970")

      result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 1000, sudo_status: 1,
                                                         extra_env: base_extra(port))
      _(result.status).must_equal 0, result.stderr
      _(result.stdout).must_include "PID #{pid} is not a proxy listening on port #{port}"
      _(result.stdout).must_include "Removed stale proxy state"
      _(result.stderr).wont_include "kill -CONT"
      _(result.capture["sudoCalls"]).must_equal []
      %w[proxy.pid proxy.port proxy.start].each { |f| _(state?(f)).must_equal false }
      _(alive_pid?(pid)).must_equal true
    ensure
      unrelated&.kill
    end

    it "removes stale proxy state when another process owns the proxy port" do
      owner = start_mock_proxy(@state_dir, portless_header: false)
      owner_pid = owner.child.pid
      unrelated = spawn_bystander
      pid = unrelated.pid
      write_state("proxy.pid", pid.to_s)
      write_state("proxy.port", owner.port.to_s)

      result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 1000, sudo_status: 1,
                                                         extra_env: base_extra(owner.port))
      _(result.status).must_equal 0, result.stderr
      _(result.stdout).must_include "PID #{pid} is not a proxy listening on port #{owner.port}"
      _(result.stdout).must_include "Removed stale proxy state"
      _(result.stderr).wont_include "kill -CONT"
      _(result.capture["sudoCalls"]).must_equal []
      %w[proxy.pid proxy.port].each { |f| _(state?(f)).must_equal false }
      _(alive_pid?(pid)).must_equal true
      _(alive_pid?(owner_pid)).must_equal true
    ensure
      unrelated&.kill
      stop_child(owner.child) if owner
    end

    it "does not erase a proxy that restarted while stopping" do
      pid_path = File.join(@state_dir, "proxy.pid")
      proxy = start_mock_proxy(@state_dir, pid_file_on_sigterm: pid_path)
      File.write(pid_path, proxy.child.pid.to_s)
      write_state("proxy.port", proxy.port.to_s)
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", state_dir: @state_dir, uid: 0, extra_env: base_extra(proxy.port))
      _(result.status).must_equal 1
      _(result.stderr).must_include "Proxy PID file changed to 999999"
      _(File.read(pid_path)).must_equal "999999"
      _(state?("proxy.port")).must_equal true
    ensure
      stop_child(proxy.child) if proxy
    end

    it "refuses a symlinked approved directory in elevated cleanup" do
      tmp = tmpdir("portless-clean-elevated-link-")
      target = File.join(tmp, "target")
      link = File.join(tmp, "state-link")
      home = File.join(tmp, "home")
      Dir.mkdir(target)
      Dir.mkdir(home)
      File.write(File.join(target, "routes.json"), "[]")
      File.symlink(target, link)
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", fail_privileged_cleanup: true, state_dir: link, uid: 1000,
                                                         extra_env: { "HOME" => home, "PORTLESS_INTERNAL_CLEAN_STEPS" => "files",
                                                                      "PORTLESS_INTERNAL_CLEAN_DIRS" => JSON.generate([ link ]) })
      _(result.status).must_equal 1
      _(result.capture["sudoCalls"]).must_equal []
      _(File.read(File.join(target, "routes.json"))).must_equal "[]"
    ensure
      rm_tmp(tmp)
    end

    it "preserves CA identity when elevated trust removal still fails" do
      linux_only!
      write_state("ca.pem", "certificate")
      write_state("ca-key.pem", "private key")
      write_state("ca.trust-refresh-pending", "1")
      result = run_with_hosts_file_mock(%w[clean --yes], content: "", fail_privileged_cleanup: true, fail_ca_always: true,
                                                         state_dir: @state_dir, uid: 1000,
                                                         extra_env: { "HOME" => @home, "PORTLESS_INTERNAL_CLEAN_STEPS" => "ca,files",
                                                                      "PORTLESS_INTERNAL_CLEAN_DIRS" => JSON.generate([ @state_dir ]) })
      _(result.status).must_equal 1
      _(read_state("ca.pem")).must_equal "certificate"
      _(read_state("ca-key.pem")).must_equal "private key"
    end

    it "refuses non-interactive cleanup without confirmation" do
      tmp = tmpdir("portless-clean-confirm-")
      routes = File.join(tmp, "routes.json")
      File.write(routes, "[]")
      r = run_cli(%w[clean], env: { "PORTLESS_STATE_DIR" => tmp, "HOME" => tmp, "USERPROFILE" => tmp })
      _(r.status).must_equal 2
      _(r.stderr).must_include "rb-portless clean --yes"
      _(File.read(routes)).must_equal "[]"
    ensure
      rm_tmp(tmp)
    end

    it "prints help with --help" do
      r = run_cli(%w[clean --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless clean"
      _(r.stdout).must_include "trust store"
      _(r.stdout).must_include "retained so clean can safely retry"
    end

    it "prints help with -h" do
      r = run_cli(%w[clean -h])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless clean"
    end

    it "rejects unknown arguments" do
      r = run_cli(%w[clean typo])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Unexpected argument"
    end

    it "does not bypass when PORTLESS=0 is set" do
      tmp = tmpdir("portless-bypass-clean-")
      r = run_cli(%w[clean], env: { "PORTLESS" => "0", "PORTLESS_STATE_DIR" => tmp, "HOME" => tmp, "USERPROFILE" => tmp })
      rm_tmp(tmp)
      _(r.stderr).wont_include "ENOENT"
    end

    it "does not bypass clean with extra args when PORTLESS=0" do
      r = run_cli(%w[clean typo], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 2
      _(r.stderr).must_include "Unexpected argument"
    end
  end

  describe "proxy subcommand" do
    it "prints help with --help" do
      r = run_cli(%w[proxy --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless proxy"
      _(r.stdout).must_include "start"
      _(r.stdout).must_include "stop"
    end

    it "prints help with -h" do
      r = run_cli(%w[proxy -h])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless proxy"
    end

    it "shows usage for bare 'proxy' without subcommand" do
      r = run_cli(%w[proxy])
      _(r.status).must_equal 0
      _(r.stdout).must_include "start"
      _(r.stdout).must_include "stop"
    end

    it "prints help instead of stopping when stop is given --help" do
      r = run_cli(%w[proxy stop -p 59999 --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless proxy stop"
    end

    it "warns when a running proxy uses a different explicit config" do
      tmp = tmpdir("portless-cli-running-proxy-")
      proxy = start_mock_proxy(tmp)
      File.write(File.join(tmp, "proxy.port"), proxy.port.to_s)
      r = run_cli(%w[proxy start --lan], env: { "PORTLESS_STATE_DIR" => tmp })
      _(r.status).must_equal 1
      _(r.stderr).must_include "Proxy is already running on port"
      _(r.stderr).must_include "requested LAN mode"
      _(r.stderr).must_include "rb-portless proxy stop"
    ensure
      stop_child(proxy.child) if proxy
      rm_tmp(tmp)
    end
  end

  describe "privileged proxy startup" do
    # Preload that makes the CLI see a non-root uid that still owns the state directory.
    def write_non_root_preload(dir)
      path = File.join(dir, "non-root-preload.rb")
      uid = Process.uid.nonzero? || 1000
      File.write(path, "Process.singleton_class.prepend(Module.new { def uid = #{uid} })\n")
      path
    end

    # A sysctl such as ip_unprivileged_port_start=0 (the Docker default) grants
    # the bind, so rb-portless correctly never reaches sudo. macOS grants it to
    # every user; there we skip without probing, since tests never bind < 1024.
    def privileged_port_is_granted?
      return true if RUBY_PLATFORM.include?("darwin")

      Portless::Privilege.can_bind_proxy_port?(443, Portless::Privilege.bind_targets(false))
    end

    def cleanup_recorded_proxy(state_dir)
      pid_path = File.join(state_dir, "proxy.pid")
      return unless File.exist?(pid_path)

      pid = Integer(File.read(pid_path), exception: false)
      return if pid.nil? || pid <= 0 || pid == Process.pid

      Process.kill("TERM", pid) rescue nil
    end

    it "exits nonzero without starting or persisting a fallback when sudo fails" do
      skip "port 443 is bindable without root here" if privileged_port_is_granted?
      tmp = tmpdir("portless-sudo-failure-")
      state_dir = File.join(tmp, "state")
      fake_bin = File.join(tmp, "bin")
      Dir.mkdir(fake_bin)
      write_exe(File.join(fake_bin, "sudo"), "#!/bin/sh\nexit 23\n")
      preload = write_non_root_preload(tmp)
      cert_path = File.join(tmp, "cert.pem")
      key_path = File.join(tmp, "key.pem")
      env = { "PATH" => "#{fake_bin}#{File::PATH_SEPARATOR}#{ENV['PATH']}", "PORTLESS_STATE_DIR" => state_dir }
      args = [ "proxy", "start", "--cert", cert_path, "--key", key_path, "--tld", "test", "--wildcard" ]
      2.times do
        result = run_cli(args, env: env, ruby_opts: [ "-r", preload ])
        output = result.stdout + result.stderr
        _(result.status).must_equal 1
        _(result.stderr).must_include "Error: Port 443 requires elevated privileges, but sudo elevation failed"
        _(result.stderr).must_include "sudo rb-portless proxy start --cert #{cert_path} --key #{key_path} --tld test --wildcard"
        _(output).wont_include "Falling back"
        _(output).wont_include "already running on port 1355"
        _(File.exist?(File.join(state_dir, "proxy.port"))).must_equal false
        _(File.exist?(File.join(state_dir, "proxy.pid"))).must_equal false
      end
    ensure
      cleanup_recorded_proxy(state_dir) if state_dir
      rm_tmp(tmp)
    end

    it "uses the same fatal path when sudo cannot be spawned" do
      skip "port 443 is bindable without root here" if privileged_port_is_granted?
      tmp = tmpdir("portless-missing-sudo-")
      state_dir = File.join(tmp, "state")
      empty_bin = File.join(tmp, "bin")
      Dir.mkdir(empty_bin)
      preload = write_non_root_preload(tmp)
      result = run_cli(%w[proxy start], env: { "PATH" => empty_bin, "PORTLESS_STATE_DIR" => state_dir }, ruby_opts: [ "-r", preload ])
      output = result.stdout + result.stderr
      _(result.status).must_equal 1
      _(result.stderr).must_include "sudo elevation failed"
      _(result.stderr).must_include "spawnSync sudo ENOENT"
      _(result.stderr).must_include "sudo rb-portless proxy start --https"
      _(output).wont_include "Falling back"
      _(File.exist?(File.join(state_dir, "proxy.port"))).must_equal false
      _(File.exist?(File.join(state_dir, "proxy.pid"))).must_equal false
    ensure
      cleanup_recorded_proxy(state_dir) if state_dir
      rm_tmp(tmp)
    end
  end

  describe "unprivileged proxy peers" do
    before { @tmp_dir = tmpdir("portless-cli-unpriv-peers-") }
    after { rm_tmp(@tmp_dir) }

    def non_loopback_ipv4
      Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? && !a.ipv4_multicast? }&.ip_address
    end

    # The status line of a plain HTTP request, or "closed" when the socket ends first.
    def request_status(host, port)
      sock = Socket.tcp(host, port, connect_timeout: 3)
      sock.write("GET / HTTP/1.1\r\nHost: demo.localhost\r\nConnection: close\r\n\r\n")
      data = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      loop do
        break unless sock.wait_readable([ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max)

        chunk = sock.readpartial(4096)
        data << chunk
      rescue EOFError, SystemCallError
        break
      end
      line = data.split("\r\n").first
      line.nil? || line.empty? ? "closed" : line
    rescue SystemCallError, IOError
      "closed"
    ensure
      sock&.close
    end

    def can_reach_self?(address)
      server = http_server("0.0.0.0") { [ 200, {}, "ok" ] }
      request_status(address, server.port).start_with?("HTTP/1.1 200")
    ensure
      server&.close
    end

    def lan_address_or_skip
      address = non_loopback_ipv4
      skip "no reachable non-loopback IPv4 address" if address.nil? || !can_reach_self?(address)
      address
    end

    it "refuses non-loopback peers on the proxy listener" do
      lan_address = lan_address_or_skip
      proxy_port = get_free_port
      env = { "PORTLESS_STATE_DIR" => @tmp_dir }
      port_args = [ "-p", proxy_port.to_s ]
      start = run_cli([ "proxy", "start", "--unprivileged", "--no-tls", *port_args ], env: env, timeout: 30)
      _(start.status).must_equal 0, start.stderr
      _(request_status("127.0.0.1", proxy_port)).must_match(%r{\AHTTP/1\.1 \d{3}})
      _(request_status(lan_address, proxy_port)).must_equal "closed"
    ensure
      run_cli([ "proxy", "stop", *port_args ], env: env) if env
    end

    it "refuses non-loopback peers on the HTTPS redirect listener" do
      skip "the redirect listener takes port 80; this suite never binds ports below 1024"
    end
  end

  describe "persisted unprivileged marker" do
    before { @tmp_dir = tmpdir("portless-cli-unpriv-marker-") }
    after { rm_tmp(@tmp_dir) }

    it "%s" do
      [
        [ "keeps unprivileged mode from the marker after a stop", nil, true ],
        [ "PORTLESS_UNPRIVILEGED=0 overrides the marker", "0", false ]
      ].each do |name, env_value, expected|
        proxy_port = get_free_port
        env = { "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_HTTPS" => "0",
                "PORTLESS_UNPRIVILEGED" => env_value }
        File.write(File.join(@tmp_dir, "proxy.unprivileged"), "1")
        begin
          start = run_cli(%w[proxy start], env: env, timeout: 30)
          _(start.status).must_equal 0, "#{name}: #{start.stderr}"
          _(File.exist?(File.join(@tmp_dir, "proxy.unprivileged"))).must_equal expected, name
        ensure
          run_cli([ "proxy", "stop", "-p", proxy_port.to_s ], env: env)
        end
      end
    end
  end

  describe "persisted proxy port" do
    before { @tmp_dir = tmpdir("portless-cli-port-marker-") }
    after { rm_tmp(@tmp_dir) }

    it "lets PORTLESS_PORT override the saved port after an unexpected exit" do
      saved_port = get_free_port
      env_port = get_free_port
      File.write(File.join(@tmp_dir, "proxy.port"), saved_port.to_s)
      env = { "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_PORT" => env_port.to_s, "PORTLESS_HTTPS" => "0" }
      r = run_cli([ "myapp", RbConfig.ruby, "-e", "exit 0" ], env: env, timeout: 30)
      _(r.status).must_equal 0, r.stderr
      _(r.stderr).must_include "http://myapp.localhost:#{env_port}"
    ensure
      run_cli([ "proxy", "stop", "-p", env_port.to_s ], env: env) if env
    end

    it "reuses the saved port after an unexpected exit without PORTLESS_PORT" do
      saved_port = get_free_port
      File.write(File.join(@tmp_dir, "proxy.port"), saved_port.to_s)
      env = { "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_HTTPS" => "0" }
      r = run_cli([ "myapp", RbConfig.ruby, "-e", "exit 0" ], env: env, timeout: 30)
      _(r.status).must_equal 0, r.stderr
      _(r.stderr).must_include "http://myapp.localhost:#{saved_port}"
    ensure
      run_cli([ "proxy", "stop", "-p", saved_port.to_s ], env: env) if env
    end
  end

  describe "persisted LAN marker" do
    before { @tmp_dir = tmpdir("portless-cli-lan-marker-") }
    after { rm_tmp(@tmp_dir) }

    it "reuses persisted LAN mode when starting the proxy again" do
      proxy_port = get_free_port
      empty_path = tmpdir("portless-empty-path-")
      File.write(File.join(@tmp_dir, "proxy.lan"), "192.168.1.42")
      r = run_cli(%w[proxy start], env: { "PATH" => empty_path, "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_PORT" => proxy_port.to_s })
      _(r.status).must_equal 1
      _(r.stderr).must_include "LAN mode requires mDNS publishing"
    ensure
      rm_tmp(empty_path)
    end

    it "PORTLESS_LAN=0 overrides the LAN marker on a fresh start" do
      proxy_port = get_free_port
      env = { "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_LAN" => "0", "PORTLESS_HTTPS" => "0" }
      File.write(File.join(@tmp_dir, "proxy.lan"), "192.168.1.42")
      r = run_cli([ "myapp", RbConfig.ruby, "-e", "exit 0" ], env: env, timeout: 30)
      _(r.status).must_equal 0, r.stderr
      _(r.stderr).must_include "http://myapp.localhost:#{proxy_port}"
      _(r.stdout).wont_include "Running:"
      _(r.stdout).wont_include "http://myapp.localhost:#{proxy_port}"
      _(File.exist?(File.join(@tmp_dir, "proxy.lan"))).must_equal false
    ensure
      run_cli(%w[proxy stop], env: env) if env
    end
  end

  describe "LAN mode" do
    before { @tmp_dir = tmpdir("portless-cli-lan-test-") }
    after { rm_tmp(@tmp_dir) }

    def run_expo(args, shim_dir, capture_path, extra = {})
      run_cli(args, env: { "PATH" => "#{shim_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}", "PORTLESS_STATE_DIR" => @tmp_dir,
                           "PORTLESS_TEST_CAPTURE_FILE" => capture_path, "PORTLESS_HTTPS" => "0" }.merge(extra))
    end

    it "rejects %j, whose --ip value is not an IP address" do
      [ %w[--ip run echo ok], %w[--ip=notanip myapp echo ok] ].each do |args|
        r = run_cli(args, env: { "PORTLESS" => "0" }, cwd: @tmp_dir)
        _(r.status).must_equal 2
        _(r.stdout).must_equal ""
        _(r.stderr).must_include "--ip requires an IP address"
      end
    end

    it "warns when --lan and --tld are both provided" do
      empty_path = tmpdir("portless-empty-path-")
      r = run_cli(%w[proxy start --lan --tld test --ip 192.168.1.42],
                  env: { "PATH" => empty_path, "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_PORT" => "19876" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "--lan forces .local TLD"
      _(r.stderr).must_include "Ignoring --tld test"
    ensure
      rm_tmp(empty_path)
    end

    it "fails early when the mDNS publisher binary is missing" do
      empty_path = tmpdir("portless-empty-path-")
      r = run_cli(%w[proxy start --foreground --lan --ip 192.168.1.42],
                  env: { "PATH" => empty_path, "PORTLESS_PORT" => "19876", "PORTLESS_STATE_DIR" => @tmp_dir })
      _(r.status).must_equal 1
      _(r.stderr).must_include "LAN mode requires mDNS publishing"
      _(r.stderr).must_include(RUBY_PLATFORM.include?("linux") ? "avahi-publish-address not found" : "dns-sd not found")
      _(r.stdout).wont_include "LAN mode active"
    ensure
      rm_tmp(empty_path)
    end

    it "propagates the LAN marker into expo child commands" do
      shim_dir = tmpdir("portless-expo-shim-")
      capture_path = File.join(shim_dir, "capture.json")
      proxy = start_mock_proxy(@tmp_dir)
      File.write(File.join(@tmp_dir, "proxy.port"), proxy.port.to_s)
      File.write(File.join(@tmp_dir, "proxy.tld"), "local")
      File.write(File.join(@tmp_dir, "proxy.lan"), "192.168.1.42")
      write_expo_shim(shim_dir)
      r = run_expo(%w[run --name mobile --app-port 4567 expo start], shim_dir, capture_path)
      _(r.status).must_equal 0, r.stderr
      capture = JSON.parse(File.read(capture_path))
      # In LAN mode, Expo gets no --host flag (Metro defaults to LAN) and no HOST env var.
      _(capture["args"]).must_equal %w[start --port 4567]
      _(capture["env"]).must_be :>=, { "PORT" => "4567", "PORTLESS_LAN" => "1", "PORTLESS_URL" => "http://mobile.local:#{proxy.port}" }
      _(capture["env"]["HOST"]).must_be_nil
    ensure
      stop_child(proxy.child) if proxy
      rm_tmp(shim_dir)
    end

    it "checks a custom local TLD when no LAN marker exists" do
      shim_dir = tmpdir("portless-custom-local-shim-")
      capture_path = File.join(shim_dir, "capture.json")
      dns_preload = File.join(shim_dir, "dns-preload.rb")
      proxy = start_mock_proxy(@tmp_dir)
      File.write(File.join(@tmp_dir, "proxy.port"), proxy.port.to_s)
      File.write(File.join(@tmp_dir, "proxy.tld"), "local")
      write_expo_shim(shim_dir)
      File.write(dns_preload, <<~'RUBY')
        require "socket"
        Addrinfo.singleton_class.prepend(Module.new do
          def getaddrinfo(*) = raise(SocketError, "getaddrinfo: nodename nor servname provided, or not known")
        end)
      RUBY
      r = run_cli(%w[run --name portless-unresolvable-test --app-port 4567 expo start],
                  env: { "PATH" => "#{shim_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}", "PORTLESS_STATE_DIR" => @tmp_dir,
                         "PORTLESS_TEST_CAPTURE_FILE" => capture_path, "PORTLESS_HTTPS" => "0" },
                  ruby_opts: [ "-r", dns_preload ])
      _(r.status).must_equal 0, r.stderr
      _(r.stderr).must_include "will not resolve"
    ensure
      stop_child(proxy.child) if proxy
      rm_tmp(shim_dir)
    end

    it "leaves Expo --lan in the child command without enabling portless LAN mode" do
      shim_dir = tmpdir("portless-expo-child-lan-shim-")
      capture_path = File.join(shim_dir, "capture.json")
      proxy = start_mock_proxy(@tmp_dir)
      File.write(File.join(@tmp_dir, "proxy.port"), proxy.port.to_s)
      write_expo_shim(shim_dir)
      r = run_expo(%w[run --name mobile --app-port 4567 expo start --lan], shim_dir, capture_path)
      _(r.status).must_equal 0, r.stderr
      capture = JSON.parse(File.read(capture_path))
      _(capture["args"]).must_equal %w[start --lan --port 4567]
      _(capture["env"]["PORTLESS_LAN"]).must_be_nil
    ensure
      stop_child(proxy.child) if proxy
      rm_tmp(shim_dir)
    end

    it "leaves --ip in the child command after the command boundary" do
      shim_dir = tmpdir("portless-expo-child-ip-shim-")
      capture_path = File.join(shim_dir, "capture.json")
      proxy = start_mock_proxy(@tmp_dir)
      File.write(File.join(@tmp_dir, "proxy.port"), proxy.port.to_s)
      write_expo_shim(shim_dir)
      r = run_expo(%w[run --name mobile --app-port 4567 expo start --ip 0.0.0.0], shim_dir, capture_path)
      _(r.status).must_equal 0, r.stderr
      capture = JSON.parse(File.read(capture_path))
      _(capture["args"]).must_equal %w[start --ip 0.0.0.0 --port 4567 --host localhost]
      _(capture["env"]["PORTLESS_LAN"]).must_be_nil
      _(capture["env"]["PORTLESS_LAN_IP"]).must_be_nil
    ensure
      stop_child(proxy.child) if proxy
      rm_tmp(shim_dir)
    end
  end

  describe "Rsbuild flag injection" do
    before { @tmp_dir = tmpdir("portless-cli-rsbuild-test-") }
    after { rm_tmp(@tmp_dir) }

    def write_rsbuild_shim(dir)
      capture_script = File.join(dir, "capture-rsbuild.rb")
      File.write(capture_script, <<~'RUBY')
        require "json"
        env = { "PORT" => ENV["PORT"], "HOST" => ENV["HOST"], "PORTLESS_URL" => ENV["PORTLESS_URL"] }.compact
        File.write(ENV["PORTLESS_TEST_CAPTURE_FILE"], JSON.generate(args: ARGV, env: env))
      RUBY
      write_exe(File.join(dir, "rsbuild"), "#!/bin/sh\n\"#{RbConfig.ruby}\" \"#{capture_script}\" \"$@\"\n")
    end

    it "injects --port and --host into rsbuild child commands" do
      shim_dir = tmpdir("portless-rsbuild-shim-")
      capture_path = File.join(shim_dir, "capture.json")
      proxy = start_mock_proxy(@tmp_dir)
      File.write(File.join(@tmp_dir, "proxy.port"), proxy.port.to_s)
      write_rsbuild_shim(shim_dir)
      r = run_cli(%w[run --name myapp --app-port 4567 rsbuild dev],
                  env: { "PATH" => "#{shim_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}", "PORTLESS_STATE_DIR" => @tmp_dir,
                         "PORTLESS_TEST_CAPTURE_FILE" => capture_path, "PORTLESS_HTTPS" => "0" })
      _(r.status).must_equal 0, r.stderr
      capture = JSON.parse(File.read(capture_path))
      _(capture["args"]).must_equal %w[dev --port 4567 --host 127.0.0.1]
      _(capture["env"]).must_be :>=, { "PORT" => "4567", "HOST" => "127.0.0.1", "PORTLESS_URL" => "http://myapp.localhost:#{proxy.port}" }
    ensure
      stop_child(proxy.child) if proxy
      rm_tmp(shim_dir)
    end

    it "registers one app route per configured TLD" do
      proxy = start_mock_proxy(@tmp_dir)
      File.write(File.join(@tmp_dir, "proxy.port"), proxy.port.to_s)
      File.write(File.join(@tmp_dir, "proxy.tlds"), "localhost\ntest\n")
      capture_path = File.join(@tmp_dir, "multi-tld-capture.json")
      script_path = File.join(@tmp_dir, "capture-routes.rb")
      File.write(script_path, <<~RUBY)
        require "json"
        routes = JSON.parse(File.read(#{File.join(@tmp_dir, 'routes.json').inspect}))
        File.write(#{capture_path.inspect}, JSON.generate(
          PORTLESS_URL: ENV["PORTLESS_URL"],
          __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS: ENV["__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS"],
          routes: routes
        ))
      RUBY
      r = run_cli([ "run", "--name", "myapp", RbConfig.ruby, script_path ], env: { "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_HTTPS" => "0" })
      _(r.status).must_equal 0, r.stderr
      capture = JSON.parse(File.read(capture_path))
      _(capture["PORTLESS_URL"]).must_equal "http://myapp.localhost:#{proxy.port}"
      _(capture["__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS"]).must_equal ".localhost,.test"
      _(capture["routes"].map { |route| route["hostname"] }.sort).must_equal %w[myapp.localhost myapp.test]
      _(capture["routes"].map { |route| route["port"] }.uniq.size).must_equal 1
    ensure
      stop_child(proxy.child) if proxy
    end
  end

  describe "NODE_EXTRA_CA_CERTS injection" do
    before { @tmp_dir = tmpdir("portless-cli-ca-test-") }
    after { rm_tmp(@tmp_dir) }

    def run_with_mock_proxy(tls: true, write_ca_pem: true, env: {})
      proxy = start_mock_proxy(@tmp_dir)
      File.write(File.join(@tmp_dir, "proxy.port"), proxy.port.to_s)
      File.write(File.join(@tmp_dir, "proxy.tls"), "1") if tls
      File.write(File.join(@tmp_dir, "ca.pem"), UpstreamCli::TEST_CA_PEM) if write_ca_pem
      capture_path = File.join(@tmp_dir, "capture.json")
      script_path = File.join(@tmp_dir, "capture-env.rb")
      File.write(script_path, "require 'json'\nFile.write(#{capture_path.inspect}, JSON.generate(NODE_EXTRA_CA_CERTS: ENV['NODE_EXTRA_CA_CERTS']))\n")
      r = run_cli([ "run", "--name", "testapp", RbConfig.ruby, script_path ], env: { "PORTLESS_STATE_DIR" => @tmp_dir }.merge(env))
      capture = File.exist?(capture_path) ? JSON.parse(File.read(capture_path)) : {}
      { status: r.status, capture: capture, stderr: r.stderr }
    ensure
      stop_child(proxy.child) if proxy
    end

    it "sets NODE_EXTRA_CA_CERTS when TLS is active and ca.pem exists" do
      r = run_with_mock_proxy(env: { "NODE_EXTRA_CA_CERTS" => nil })
      _(r[:status]).must_equal 0, r[:stderr]
      _(r[:capture]["NODE_EXTRA_CA_CERTS"]).must_equal File.join(@tmp_dir, "ca.pem")
    end

    it "does not set NODE_EXTRA_CA_CERTS when TLS is disabled" do
      r = run_with_mock_proxy(tls: false, env: { "PORTLESS_HTTPS" => "0", "NODE_EXTRA_CA_CERTS" => nil })
      _(r[:status]).must_equal 0, r[:stderr]
      _(r[:capture]["NODE_EXTRA_CA_CERTS"]).must_be_nil
    end

    it "does not set NODE_EXTRA_CA_CERTS when ca.pem is missing" do
      r = run_with_mock_proxy(write_ca_pem: false, env: { "NODE_EXTRA_CA_CERTS" => nil })
      _(r[:status]).must_equal 0, r[:stderr]
      _(r[:capture]["NODE_EXTRA_CA_CERTS"]).must_be_nil
    end

    it "does not override user-set NODE_EXTRA_CA_CERTS" do
      user_ca_path = "/custom/ca.pem"
      r = run_with_mock_proxy(env: { "NODE_EXTRA_CA_CERTS" => user_ca_path })
      _(r[:status]).must_equal 0, r[:stderr]
      _(r[:capture]["NODE_EXTRA_CA_CERTS"]).must_equal user_ca_path
    end
  end

  describe "get subcommand" do
    before { @tmp_dir = tmpdir("portless-cli-get-test-") }
    after { rm_tmp(@tmp_dir) }

    def get_env = { "PORTLESS_STATE_DIR" => @tmp_dir }

    def fake_worktree(root, branch = "team-a/login")
      gitdir = File.join(root, "fake.git", "worktrees", "wt")
      FileUtils.mkdir_p(gitdir)
      File.write(File.join(gitdir, "HEAD"), "ref: refs/heads/#{branch}\n")
      File.write(File.join(root, ".git"), "gitdir: #{gitdir}\n")
    end

    it "prints help with --help" do
      r = run_cli(%w[get --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless get"
      _(r.stdout).must_include "--no-worktree"
    end

    it "prints help with -h" do
      r = run_cli(%w[get -h])
      _(r.status).must_equal 0
      _(r.stdout).must_include "rb-portless get"
    end

    it "exits 2 with usage when no name given" do
      r = run_cli(%w[get])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Missing service name"
    end

    it "prints URL for a given service name" do
      r = run_cli(%w[get backend], cwd: @tmp_dir, env: get_env)
      _(r.status).must_equal 0
      _(r.stdout.strip).must_match(%r{\Ahttps?://backend\.localhost(:\d+)?\z})
    end

    it "prints get JSON using the same worktree-aware URL as plain get" do
      options = { cwd: @tmp_dir, env: get_env.merge("PORTLESS_PREFIX" => "feature") }
      plain = run_cli(%w[get backend], **options)
      json = run_cli(%w[get backend --json], **options)
      _(json.status).must_equal 0
      _(JSON.parse(json.stdout)).must_equal({ "name" => "backend", "hostname" => "feature.backend.localhost", "url" => plain.stdout.strip })
      no_worktree = run_cli(%w[get backend --json --no-worktree], **options)
      _(JSON.parse(no_worktree.stdout)["hostname"]).must_equal "backend.localhost"
    end

    it "prints URL for a dotted service name" do
      r = run_cli(%w[get api.backend], cwd: @tmp_dir, env: get_env)
      _(r.status).must_equal 0
      _(r.stdout.strip).must_match(%r{\Ahttps?://api\.backend\.localhost(:\d+)?\z})
    end

    it "rejects unknown flags" do
      r = run_cli(%w[get --typo backend])
      _(r.status).must_equal 2
      _(r.stderr).must_include "Unknown flag"
    end

    it "accepts --no-worktree flag" do
      r = run_cli(%w[get --no-worktree backend], env: get_env)
      _(r.status).must_equal 0
      _(r.stdout.strip).must_match(%r{\Ahttps?://backend\.localhost(:\d+)?\z})
    end

    it "composes a whole hostname template with the branch style" do
      fake_worktree(@tmp_dir)
      File.write(File.join(@tmp_dir, "portless.json"),
                 JSON.generate(name: "myapp", worktree: { prefix: "branch", hostnameTemplate: "tenant.{worktree}-{name}" }))
      r = run_cli(%w[get myapp], cwd: @tmp_dir, env: get_env)
      _(r.status).must_equal 0, r.stderr
      _(r.stdout.strip).must_match(%r{\Ahttps?://tenant\.team-a-login-myapp\.localhost(:\d+)?\z})
    end

    it "uses the template for a nonempty PORTLESS_PREFIX and skips it when empty" do
      fake_worktree(@tmp_dir)
      File.write(File.join(@tmp_dir, "portless.json"),
                 JSON.generate(name: "myapp", worktree: { hostnameTemplate: "tenant.{worktree}-{name}" }))
      labelled = run_cli(%w[get myapp], cwd: @tmp_dir, env: get_env.merge("PORTLESS_PREFIX" => "hotfix"))
      _(labelled.stdout.strip).must_match(%r{\Ahttps?://tenant\.hotfix-myapp\.localhost(:\d+)?\z})
      unlabelled = run_cli(%w[get myapp], cwd: @tmp_dir, env: get_env.merge("PORTLESS_PREFIX" => ""))
      _(unlabelled.stdout.strip).must_match(%r{\Ahttps?://myapp\.localhost(:\d+)?\z})
    end

    it "inherits workspace root worktree options in a package" do
      root = File.join(@tmp_dir, "mono")
      leaf = File.join(root, "packages", "web")
      FileUtils.mkdir_p(leaf)
      File.write(File.join(root, "package.json"), JSON.generate(name: "mono", private: true, workspaces: [ "packages/*" ]))
      File.write(File.join(root, "portless.json"),
                 JSON.generate(worktree: { prefix: "branch" },
                               apps: { "packages/web" => { worktree: { hostnameTemplate: "tenant.{worktree}-{name}" } } }))
      File.write(File.join(leaf, "package.json"), JSON.generate(name: "web"))
      fake_worktree(root)

      root_only = run_cli(%w[get web], cwd: leaf, env: get_env)
      _(root_only.status).must_equal 0, root_only.stderr
      _(root_only.stdout.strip).must_match(%r{\Ahttps?://tenant\.team-a-login-web\.localhost(:\d+)?\z})

      File.write(File.join(leaf, "portless.json"), JSON.generate(worktree: { prefix: "last-segment" }))
      local_override = run_cli(%w[get web], cwd: leaf, env: get_env)
      _(local_override.status).must_equal 0, local_override.stderr
      _(local_override.stdout.strip).must_match(%r{\Ahttps?://tenant\.login-web\.localhost(:\d+)?\z})
    end

    it "exits 1 for invalid hostname" do
      r = run_cli(%w[get my@app])
      _(r.status).must_equal 1
      _(r.stderr).must_include "Invalid hostname"
    end

    it "handles malformed $scenario" do
      [
        { scenario: "workspace root config", file: "root", cwd: "leaf", flags: [], status: 1 },
        { scenario: "package config", file: "leaf", cwd: "leaf", flags: [], status: 1 },
        { scenario: "package config with --no-worktree", file: "leaf", cwd: "leaf", flags: [ "--no-worktree" ], status: 0 }
      ].each do |c|
        root = File.join(@tmp_dir, "mono")
        FileUtils.rm_rf(root)
        leaf = File.join(root, "packages", "web")
        FileUtils.mkdir_p(leaf)
        File.write(File.join(root, "package.json"), JSON.generate(name: "mono", private: true, workspaces: [ "packages/*" ]))
        File.write(File.join(leaf, "package.json"), JSON.generate(name: "web"))
        File.write(File.join(c[:file] == "root" ? root : leaf, "portless.json"), "{ invalid")

        result = run_cli([ "get", *c[:flags], "web" ], cwd: c[:cwd] == "root" ? root : leaf, env: get_env)
        _(result.status).must_equal c[:status], c[:scenario]
        if c[:status].zero?
          _(result.stdout).must_include "web.localhost"
        else
          _(result.stderr).must_include "Invalid JSON"
        end
      end
    end
  end

  describe "--name flag" do
    it "treats reserved word as app name with PORTLESS=0" do
      r = run_cli(%w[--name run echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "ok"
    end

    it "passes --force through with --name (PORTLESS=0)" do
      r = run_cli(%w[--name alias --force echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "ok"
    end

    it "exits 2 when --name has no value" do
      r = run_cli(%w[--name])
      _(r.status).must_equal 2
      _(r.stderr).must_include "--name requires"
    end

    it "exits 2 when --name has name but no command" do
      r = run_cli(%w[--name myapp])
      _(r.status).must_equal 2
      _(r.stderr).must_include "No command provided"
    end
  end

  describe "run --name flag" do
    it "shows --name in run help" do
      r = run_cli(%w[run --help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "--name"
    end

    it "strips --name and passes command through (PORTLESS=0)" do
      r = run_cli(%w[run --name custom echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "ok"
    end

    it "exits 2 when --name has no value" do
      r = run_cli(%w[run --name])
      _(r.status).must_equal 2
      _(r.stderr).must_include "--name requires"
    end

    it "exits 2 when --name value looks like a flag" do
      r = run_cli(%w[run --name --force echo ok])
      _(r.status).must_equal 2
      _(r.stderr).must_include "--name requires"
    end

    it "combines --name with --force (PORTLESS=0)" do
      r = run_cli(%w[run --name foo --force echo ok], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "ok"
    end

    it "does not consume --name after -- separator (PORTLESS=0)" do
      r = run_cli(%w[run -- echo --name foo], env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0
      _(r.stdout.strip).must_equal "--name foo"
    end
  end

  describe "proxy start/stop lifecycle" do
    before do
      @tmp_dir = tmpdir("portless-lifecycle-")
      @test_port = get_free_port
    end

    after do
      run_cli(%w[proxy stop], env: proxy_env)
      rm_tmp(@tmp_dir)
    end

    def proxy_env = { "PORTLESS_PORT" => @test_port.to_s, "PORTLESS_HTTPS" => "0", "PORTLESS_STATE_DIR" => @tmp_dir }
    def proxy_log = File.read(File.join(@tmp_dir, "proxy.log"))
    def start_proxy(args = [], env = {}) = run_cli([ "proxy", "start", *args ], env: proxy_env.merge(env), timeout: 30)

    it "starts the proxy and stops it cleanly" do
      start = start_proxy
      _(start.status).must_equal 0, start.stderr
      _(start.stdout).must_include "proxy started on port #{@test_port}"

      stop = run_cli(%w[proxy stop], env: proxy_env)
      _(stop.status).must_equal 0
      _(stop.stdout).must_include "Proxy stopped"
    end

    it "binds the wildcard address and remembers the mode with --unprivileged" do
      start = start_proxy([ "--unprivileged" ])
      _(start.status).must_equal 0, start.stderr
      wait_for_http_header(@test_port, "X-Portless", "1")

      _(File.exist?(File.join(@tmp_dir, "proxy.unprivileged"))).must_equal true
      log = proxy_log
      _(log).must_include "listening on 0.0.0.0:#{@test_port}"
      _(log).must_include "(unprivileged, loopback peers only)"

      stop = run_cli(%w[proxy stop], env: proxy_env)
      _(stop.status).must_equal 0
      _(File.exist?(File.join(@tmp_dir, "proxy.unprivileged"))).must_equal true
    end

    it "reads unprivileged mode from PORTLESS_UNPRIVILEGED" do
      start = start_proxy([], "PORTLESS_UNPRIVILEGED" => "1")
      _(start.status).must_equal 0, start.stderr
      wait_for_http_header(@test_port, "X-Portless", "1")
      _(File.exist?(File.join(@tmp_dir, "proxy.unprivileged"))).must_equal true
    end

    it "serves plain HTTP in unprivileged mode unless HTTPS is explicit" do
      start = start_proxy([ "--unprivileged" ], "PORTLESS_HTTPS" => nil)
      _(start.status).must_equal 0, start.stderr
      wait_for_http_header(@test_port, "X-Portless", "1")
      _(File.exist?(File.join(@tmp_dir, "proxy.tls"))).must_equal false
      _(proxy_log).must_include "HTTP proxy listening on 0.0.0.0:#{@test_port}"
    end

    it "keeps HTTPS in unprivileged mode when asked, without touching the trust store" do
      start = start_proxy(%w[--unprivileged --https], "PORTLESS_HTTPS" => nil)
      _(start.status).must_equal 0, start.stderr
      wait_for_http_header(@test_port, "X-Portless", "1")
      _(File.exist?(File.join(@tmp_dir, "proxy.tls"))).must_equal true
      _(start.stdout + start.stderr).wont_include "Adding CA to system trust store"
    end

    it "serves HTTPS with --https even when PORTLESS_HTTPS=0 (%s)" do
      %w[daemon foreground].each do |mode|
        home_dir = tmpdir("portless-home-")
        child = nil
        begin
          env = proxy_env.merge("HOME" => home_dir, "USERPROFILE" => home_dir)
          args = [ "proxy", "start", "--https", "--skip-trust", "-p", @test_port.to_s ]
          if mode == "foreground"
            child = spawn_bg(cli_argv(*args, "--foreground"), env: env.merge("NO_COLOR" => "1", "PNPM_SCRIPT_SRC_DIR" => nil,
                                                                           "npm_command" => nil), out: false)
          else
            start = run_cli(args, env: env, timeout: 30)
            _(start.status).must_equal 0, start.stdout + start.stderr
          end
          wait_for_https_header(@test_port)
          http = Net::HTTP.new("127.0.0.1", @test_port)
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          http.open_timeout = 2
          http.read_timeout = 2
          header = http.start { |c| c.get("/")["x-portless"] }
          _(header).must_equal "1", mode
        ensure
          stop_child(child) if child
          run_cli(%w[proxy stop], env: proxy_env)
          rm_tmp(home_dir)
        end
      end
    end

    it "never writes the hosts file in unprivileged mode" do
      start = start_proxy([ "--unprivileged" ])
      _(start.status).must_equal 0, start.stderr
      wait_for_http_header(@test_port, "X-Portless", "1")
      alias_result = run_cli(%w[alias hostsless 4567], env: proxy_env)
      _(alias_result.status).must_equal 0, alias_result.stderr
      _(proxy_log).wont_include "Could not write"
    end

    it "refuses PORTLESS_SYNC_HOSTS=1 together with --unprivileged" do
      start = start_proxy([ "--unprivileged" ], "PORTLESS_SYNC_HOSTS" => "1")
      _(start.status).must_equal 1
      _(start.stderr).must_include "cannot be combined with unprivileged mode"
      _(start.stderr).must_include "rb-portless hosts sync"
    end

    it "says up front that a custom TLD needs hosts entries in unprivileged mode" do
      start = start_proxy(%w[--unprivileged --tld test])
      _(start.status).must_equal 0, start.stderr
      _(start.stdout + start.stderr).must_include "Hosts sync is disabled"
      _(start.stdout + start.stderr).must_include "rb-portless hosts sync"
      wait_for_http_header(@test_port, "X-Portless", "1")
    end

    it "keeps binding loopback only without the flag" do
      start = start_proxy
      _(start.status).must_equal 0, start.stderr
      wait_for_http_header(@test_port, "X-Portless", "1")
      log = proxy_log
      _(log).must_include "listening on 127.0.0.1:#{@test_port}"
      _(log).wont_include "unprivileged"
      _(File.exist?(File.join(@tmp_dir, "proxy.unprivileged"))).must_equal false
    end

    it "accepts connections on IPv6 loopback when available" do
      begin
        TCPServer.new("::1", 0).close
      rescue Errno::EAFNOSUPPORT, Errno::EADDRNOTAVAIL
        skip "no IPv6 loopback"
      end
      start = start_proxy
      _(start.status).must_equal 0, start.stderr
      wait_for_http_header(@test_port, "X-Portless", "1", "::1")
    end

    it "reports not running when stopped twice" do
      start = start_proxy
      _(start.status).must_equal 0, start.stderr
      stop1 = run_cli(%w[proxy stop], env: proxy_env)
      _(stop1.status).must_equal 0
      stop2 = run_cli(%w[proxy stop], env: proxy_env)
      _(stop2.stdout).must_include "not running"
    end

    it "detects an already-running proxy on start" do
      start1 = start_proxy
      _(start1.status).must_equal 0, start1.stderr
      start2 = start_proxy
      _(start2.stdout).must_include "already running"
    end

    it "stops proxy using explicit -p flag instead of env var" do
      start = start_proxy
      _(start.status).must_equal 0, start.stderr
      stop = run_cli([ "proxy", "stop", "-p", @test_port.to_s ], env: { "PORTLESS_HTTPS" => "0", "PORTLESS_STATE_DIR" => @tmp_dir })
      _(stop.status).must_equal 0
      _(stop.stdout).must_include "Proxy stopped"
    end
  end

  describe "HTTPS proxy with broken security binary (#228)" do
    before do
      @tmp_dir = tmpdir("portless-trust-timeout-")
      @test_port = get_free_port
      # A `security` that always fails, like an unresponsive Keychain daemon.
      @fake_bin_dir = tmpdir("portless-fake-bin-")
      write_exe(File.join(@fake_bin_dir, "security"), "#!/bin/sh\nexit 1\n")
    end

    after do
      run_cli([ "proxy", "stop", "-p", @test_port.to_s ], env: { "PORTLESS_STATE_DIR" => @tmp_dir })
      rm_tmp(@tmp_dir)
      rm_tmp(@fake_bin_dir)
    end

    it "starts HTTPS proxy when security commands fail" do
      skip "macOS only" unless RUBY_PLATFORM.include?("darwin")
      env = { "PORTLESS_PORT" => @test_port.to_s, "PORTLESS_STATE_DIR" => @tmp_dir,
              "PATH" => "#{@fake_bin_dir}:#{ENV['PATH']}" }
      start = run_cli(%w[proxy start], env: env, timeout: 30)
      _(start.status).must_equal 0, start.stdout + start.stderr
      _(start.stdout).must_include "proxy started on port #{@test_port}"
      combined = start.stdout + start.stderr
      _(combined).must_include "Could not add CA to system trust store"
      log_path = File.join(@tmp_dir, "proxy.log")
      if File.exist?(log_path)
        log = File.read(log_path)
        _(log).wont_include "Adding CA to system trust store"
        _(log).must_include "HTTPS/2 proxy listening"
      end
    end
  end

  describe "portless.json config" do
    before { @tmp_dir = tmpdir("portless-cli-config-") }
    after { rm_tmp(@tmp_dir) }

    def write_json(name, data, dir = @tmp_dir) = File.write(File.join(dir, name), data.is_a?(String) ? data : JSON.generate(data))
    def ruby_e(code) = "#{RbConfig.ruby} -e #{code.inspect}"

    # Run the CLI against a fake package-manager binary (shim) that records the
    # args and env it was invoked with.
    def capture_script_delegation(pm:, script:, cli_args:, lan: false, prefix_env: nil, worktree: nil)
      shim_dir = tmpdir("portless-pm-shim-")
      capture_path = File.join(shim_dir, "capture.json")
      proxy = start_mock_proxy(@tmp_dir)
      write_json("proxy.port", proxy.port.to_s)
      write_json("proxy.lan", "192.168.1.42") if lan
      portless = { appPort: 4567 }
      portless[:worktree] = worktree if worktree
      write_json("package.json", { name: "test-app", packageManager: "#{pm}@1.0.0", portless: portless, scripts: { dev: script } })

      capture_script = File.join(shim_dir, "capture-pm.rb")
      File.write(capture_script, <<~'RUBY')
        require "json"
        keys = %w[PORT HOST PORTLESS_URL PORTLESS_LAN PORTLESS_PREFIX]
        File.write(ENV["PORTLESS_TEST_CAPTURE_FILE"], JSON.generate(args: ARGV, env: keys.to_h { |k| [ k, ENV[k] ] }.compact))
      RUBY
      # The shim lives in node_modules/.bin, which the child PATH puts first.
      local_bin = File.join(@tmp_dir, "node_modules", ".bin")
      FileUtils.mkdir_p(local_bin)
      write_exe(File.join(local_bin, pm), "#!/bin/sh\n\"#{RbConfig.ruby}\" \"#{capture_script}\" \"$@\"\n")

      env = { "PATH" => [ File.expand_path("../support/bin", __dir__), "/usr/bin", "/bin" ].join(File::PATH_SEPARATOR),
              "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_TEST_CAPTURE_FILE" => capture_path, "PORTLESS_HTTPS" => "0" }
      env["PORTLESS_PREFIX"] = prefix_env unless prefix_env.nil?
      r = run_cli(cli_args, cwd: @tmp_dir, env: env)
      unless File.exist?(capture_path)
        raise [ "package-manager shim never ran (#{pm})", "exit: #{r.status}", "stdout: #{r.stdout.strip}",
                "stderr: #{r.stderr.strip}" ].join("\n")
      end
      { status: r.status, proxy_port: proxy.port, capture: JSON.parse(File.read(capture_path)) }
    ensure
      stop_child(proxy.child) if proxy
      rm_tmp(shim_dir)
    end

    it "portless (no args) runs dev script without portless.json" do
      write_json("package.json", { name: "test-app", scripts: { dev: "echo hello" } })
      r = run_cli([], cwd: @tmp_dir, env: { "PORTLESS" => "0" })
      _(r.status).must_equal 0, r.stderr
      _(r.stdout).must_include "hello"
    end

    it "bare portless gives the app PORTLESS_APP_PORT over portless.json appPort" do
      proxy_port = get_free_port
      config_port = get_free_port
      env_port = get_free_port
      env_port = get_free_port while env_port == config_port || env_port == proxy_port
      proxy_env = { "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_HTTPS" => "0" }
      write_json("package.json", { name: "test-app", scripts: { dev: "#{RbConfig.ruby} dev.rb" } })
      File.write(File.join(@tmp_dir, "dev.rb"), <<~'RUBY')
        require "json"
        require "socket"
        server = TCPServer.new("127.0.0.1", Integer(ENV["PORT"]))
        File.write("port.json", JSON.generate(envPort: Integer(ENV["PORT"]), boundPort: server.addr[1]))
        server.close
      RUBY
      write_json("portless.json", { name: "test-app", appPort: config_port })
      start = run_cli(%w[proxy start], env: proxy_env, timeout: 30)
      _(start.status).must_equal 0, start.stdout + start.stderr
      result = run_cli([], cwd: @tmp_dir, env: proxy_env.merge("PORTLESS_APP_PORT" => env_port.to_s), timeout: 30)
      _(result.status).must_equal 0, result.stdout + result.stderr
      _(JSON.parse(File.read(File.join(@tmp_dir, "port.json")))).must_equal({ "envPort" => env_port, "boundPort" => env_port })
    ensure
      run_cli(%w[proxy stop], env: proxy_env) if proxy_env
    end

    it "omits HOST for an expo package script in LAN mode" do
      r = capture_script_delegation(pm: "bun", script: "expo start", cli_args: [], lan: true)
      _(r[:status]).must_equal 0
      _(r[:capture]["env"]["PORTLESS_LAN"]).must_equal "1"
      _(r[:capture]["env"]["HOST"]).must_be_nil
    end

    it "omits HOST for an expo script it declines to append to" do
      r = capture_script_delegation(pm: "bun", script: "expo start --port 4567 # note", cli_args: [], lan: true)
      _(r[:status]).must_equal 0
      _(r[:capture]["args"]).must_equal %w[run dev]
      _(r[:capture]["env"]["HOST"]).must_be_nil
    end

    it "portless (no args) forwards Vite port flags through bun run dev" do
      r = capture_script_delegation(pm: "bun", script: "vite dev --host 127.0.0.1", cli_args: [])
      _(r[:status]).must_equal 0
      _(r[:capture]["args"]).must_equal %w[run dev --port 4567 --strictPort]
      _(r[:capture]["env"]).must_be :>=, { "PORT" => "4567", "HOST" => "127.0.0.1",
                                           "PORTLESS_URL" => "http://test-app.localhost:#{r[:proxy_port]}" }
    end

    it "portless run <pm> run <script> forwards Vite port flags (explicit delegation)" do
      r = capture_script_delegation(pm: "bun", script: "vite dev --host 127.0.0.1", cli_args: %w[run bun run dev])
      _(r[:status]).must_equal 0
      _(r[:capture]["args"]).must_equal %w[run dev --port 4567 --strictPort]
    end

    it "does not forward flags when the script already sets --port" do
      r = capture_script_delegation(pm: "bun", script: "vite dev --port 5000 --host 127.0.0.1", cli_args: [])
      _(r[:status]).must_equal 0
      _(r[:capture]["args"]).must_equal %w[run dev]
    end

    it "does not forward flags for non-framework scripts" do
      r = capture_script_delegation(pm: "bun", script: "node server.js", cli_args: [])
      _(r[:status]).must_equal 0
      _(r[:capture]["args"]).must_equal %w[run dev]
    end

    it "run --prefix beats PORTLESS_PREFIX and get agrees on the template" do
      r = capture_script_delegation(pm: "bun", script: "node server.js", cli_args: %w[run --prefix flag --script dev],
                                    prefix_env: "shell", worktree: { hostnameTemplate: "tenant.{worktree}-{name}" })
      _(r[:status]).must_equal 0
      launched = r[:capture]["env"]["PORTLESS_URL"]
      _(launched).must_include "tenant.flag-test-app.localhost"
      got = run_cli(%w[get test-app], cwd: @tmp_dir, env: { "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_HTTPS" => "0",
                                                            "PORTLESS_PREFIX" => r[:capture]["env"]["PORTLESS_PREFIX"] })
      _(got.stdout.strip).must_equal launched
    end

    it "handles shared template names (proxyA=$proxyA)" do
      [ { proxy_a: true, error: "Duplicate hostname" }, { proxy_a: false, error: "2 apps exited with errors:" } ].each do |c|
        FileUtils.rm_rf(Dir.glob(File.join(@tmp_dir, "*")))
        proxy = start_mock_proxy(@tmp_dir)
        begin
          write_json("package.json", { name: "mono", private: true, workspaces: [ "packages/*" ] })
          write_json("portless.json", { worktree: { hostnameTemplate: "tenant.{worktree}" } })
          %w[a b].each do |name|
            dir = File.join(@tmp_dir, "packages", name)
            FileUtils.mkdir_p(dir)
            write_json("package.json", { name: name, scripts: { dev: ruby_e("exit #{name == 'a' ? 7 : 3}") },
                                         portless: { proxy: name != "a" || c[:proxy_a] } }, dir)
          end
          write_json("proxy.port", proxy.port.to_s)
          r = run_cli([], cwd: @tmp_dir, env: { "PORTLESS_STATE_DIR" => @tmp_dir, "PORTLESS_HTTPS" => "0", "PORTLESS_PREFIX" => "review" },
                          timeout: 30)
          _(r.status).must_equal 1, "proxyA=#{c[:proxy_a]}: #{r.stderr}"
          _(r.stderr).must_include c[:error]
          _(File.exist?(File.join(@tmp_dir, "routes.json"))).must_equal false if c[:proxy_a]
        ensure
          stop_child(proxy.child)
        end
      end
    end

    it "rejects canonical hostname collisions before starting the proxy or apps" do
      state_dir = File.join(@tmp_dir, "state")
      ran_file = File.join(state_dir, "app-ran.txt")
      proxy_port = get_free_port
      Dir.mkdir(state_dir)
      write_json("package.json", { name: "dup", private: true, workspaces: [ "packages/*" ] })
      # "api" and "api.localhost" both canonicalize to api.localhost.
      write_json("portless.json", { apps: { "packages/api" => { name: "api", proxy: true },
                                            "packages/api.localhost" => { name: "api.localhost", proxy: true } } })
      %w[api api.localhost].each do |name|
        dir = File.join(@tmp_dir, "packages", name)
        FileUtils.mkdir_p(dir)
        write_json("package.json", { name: name, scripts: { dev: ruby_e("File.write(ENV['RAN_FILE'], 'ran', mode: 'a')") } }, dir)
      end
      r = run_cli([], cwd: @tmp_dir, env: { "PORTLESS_STATE_DIR" => state_dir, "PORTLESS_PORT" => proxy_port.to_s,
                                            "PORTLESS_HTTPS" => "0", "RAN_FILE" => ran_file }, timeout: 30)
      _(r.status).must_equal 1
      _(r.stderr).must_include 'Duplicate hostname "api.localhost"'
      _(r.stderr).must_include '"api"'
      _(r.stderr).must_include '"api.localhost"'
      _(File.exist?(File.join(state_dir, "proxy.pid"))).must_equal false
      _(File.exist?(ran_file)).must_equal false
    ensure
      run_cli(%w[proxy stop], env: { "PORTLESS_STATE_DIR" => state_dir, "PORTLESS_HTTPS" => "0" }) if state_dir
    end

    it "portless run (no command) with portless.json resolves dev script" do
      write_json("package.json", { name: "test-app", scripts: { dev: "echo config-dev" } })
      write_json("portless.json", { name: "myapp" })
      r = run_cli(%w[run], cwd: @tmp_dir, env: { "PORTLESS" => "0" })
      _(r.stdout).must_include "config-dev"
    end

    it "portless run (no command) without portless.json resolves dev script" do
      write_json("package.json", { name: "test-app", scripts: { dev: "echo hello" } })
      r = run_cli(%w[run], cwd: @tmp_dir, env: { "PORTLESS" => "0" })
      _(r.stdout).must_include "hello"
    end

    it "portless run with explicit command ignores config script" do
      write_json("package.json", { name: "test-app", scripts: { dev: "echo from-config" } })
      write_json("portless.json", { name: "myapp", script: "dev" })
      r = run_cli(%w[run echo from-cli], cwd: @tmp_dir, env: { "PORTLESS" => "0" })
      _(r.stdout).must_include "from-cli"
      _(r.stdout).wont_include "from-config"
    end

    it "portless run with portless.json script field uses that script" do
      write_json("package.json", { name: "test-app", scripts: { dev: "echo from-dev", start: "echo from-start" } })
      write_json("portless.json", { name: "myapp", script: "start" })
      r = run_cli(%w[run], cwd: @tmp_dir, env: { "PORTLESS" => "0" })
      _(r.stdout).must_include "from-start"
    end

    it "--script flag overrides config script field" do
      write_json("package.json", { name: "test-app", scripts: { dev: "echo from-dev", start: "echo from-start" } })
      write_json("portless.json", { name: "myapp", script: "dev" })
      r = run_cli(%w[--script start run], cwd: @tmp_dir, env: { "PORTLESS" => "0" })
      _(r.stdout).must_include "from-start"
    end

    it "--name overrides portless.json name" do
      write_json("package.json", { name: "test-app", scripts: { dev: "echo hello" } })
      write_json("portless.json", { name: "config-name" })
      r = run_cli(%w[--name override-name echo works], cwd: @tmp_dir, env: { "PORTLESS" => "0" })
      _(r.stdout).must_include "works"
    end

    it "portless run with missing script errors clearly" do
      write_json("package.json", { name: "test-app", scripts: {} })
      write_json("portless.json", { name: "myapp", script: "nonexistent" })
      r = run_cli(%w[run], cwd: @tmp_dir)
      _(r.status).must_equal 2
      _(r.stderr).must_include "No command provided"
    end

    it "portless.json validation rejects invalid appPort" do
      write_json("package.json", { name: "test-app", scripts: { dev: "echo hello" } })
      write_json("portless.json", { appPort: "not-a-number" })
      r = run_cli(%w[run], cwd: @tmp_dir)
      _(r.status).must_equal 1
      _(r.stderr).must_include "appPort"
    end
  end

  describe "--tailscale flag" do
    it "shows --tailscale in help output" do
      r = run_cli(%w[--help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "--tailscale"
      _(r.stdout).must_include "--funnel"
    end

    it "fails with actionable message when tailscale is not installed" do
      r = run_cli(%w[--tailscale myapp echo hello], env: { "PATH" => "/tmp/portless-no-ts-path" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "Tailscale"
    end

    it "fails with --funnel when tailscale is not installed" do
      r = run_cli(%w[--funnel myapp echo hello], env: { "PATH" => "/tmp/portless-no-ts-path" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "Tailscale"
    end

    it "accepts PORTLESS_TAILSCALE=1 env var" do
      r = run_cli(%w[myapp echo hello], env: { "PORTLESS_TAILSCALE" => "1", "PATH" => "/tmp/portless-no-ts-path" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "Tailscale"
    end

    it "accepts --tailscale after app name" do
      r = run_cli(%w[myapp --tailscale echo hello], env: { "PATH" => "/tmp/portless-no-ts-path" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "Tailscale"
    end

    it "accepts --tailscale in run subcommand" do
      tmp = tmpdir("portless-cli-ts-run-")
      File.write(File.join(tmp, "package.json"), JSON.generate(name: "test-app"))
      r = run_cli(%w[run --tailscale echo hello], cwd: tmp, env: { "PATH" => "/tmp/portless-no-ts-path" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "Tailscale"
    ensure
      rm_tmp(tmp)
    end
  end

  describe "--ngrok flag" do
    it "shows --ngrok in help output" do
      r = run_cli(%w[--help])
      _(r.status).must_equal 0
      _(r.stdout).must_include "--ngrok"
    end

    it "fails with actionable message when ngrok is not installed" do
      r = run_cli(%w[--ngrok myapp echo hello], env: { "PATH" => "/tmp/portless-no-ngrok-path" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "ngrok CLI not found"
    end

    it "accepts PORTLESS_NGROK=1 env var" do
      r = run_cli(%w[myapp echo hello], env: { "PORTLESS_NGROK" => "1", "PATH" => "/tmp/portless-no-ngrok-path" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "ngrok CLI not found"
    end

    it "accepts --ngrok after app name" do
      r = run_cli(%w[myapp --ngrok echo hello], env: { "PATH" => "/tmp/portless-no-ngrok-path" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "ngrok CLI not found"
    end

    it "accepts --ngrok in run subcommand" do
      tmp = tmpdir("portless-cli-ngrok-run-")
      File.write(File.join(tmp, "package.json"), JSON.generate(name: "test-app"))
      r = run_cli(%w[run --ngrok echo hello], cwd: tmp, env: { "PATH" => "/tmp/portless-no-ngrok-path" })
      _(r.status).must_equal 1
      _(r.stderr).must_include "ngrok CLI not found"
    ensure
      rm_tmp(tmp)
    end
  end

  describe "tunnel status streams" do
    it "reports the $name tunnel on stderr and leaves child stdout alone" do
      [
        {
          name: "tailscale", app_args: %w[--tailscale myapp], binary: "tailscale",
          script: [
            "#!/bin/sh",
            'case "$1" in',
            "  version) echo 1.80.0 ;;",
            "  status) printf '%s\\n' '{\"Self\":{\"DNSName\":\"portless-test.tail1234.ts.net.\",\"Capabilities\":[\"https\"]}}' ;;",
            '  serve) if [ "$2" = status ]; then echo "{}"; fi ;;',
            "esac",
            "exit 0",
            ""
          ].join("\n"),
          tunnel_line: "Tailscale -> https://portless-test.tail1234.ts.net",
          status_line: "accessible from your tailnet"
        },
        {
          name: "ngrok", app_args: %w[--ngrok myapp], binary: "ngrok",
          script: [
            "#!/bin/sh",
            'case "$1" in',
            "  version) echo 3.0.0 ;;",
            "  http)",
            '    echo "t=0 lvl=info msg=started-tunnel url=https://portless-test.ngrok-free.app"',
            "    while true; do sleep 1; done ;;",
            "esac",
            "exit 0",
            ""
          ].join("\n"),
          tunnel_line: "ngrok -> https://portless-test.ngrok-free.app",
          status_line: "accessible from the public internet via ngrok"
        }
      ].each do |c|
        tmp = tmpdir("portless-tunnel-streams-")
        bin_dir = File.join(tmp, "bin")
        Dir.mkdir(bin_dir)
        proxy = start_mock_proxy(tmp)
        begin
          File.write(File.join(tmp, "proxy.port"), proxy.port.to_s)
          write_exe(File.join(bin_dir, c[:binary]), c[:script])
          sentinel = "child-stdout-sentinel"
          r = run_cli([ *c[:app_args], RbConfig.ruby, "-e", "$stdout.write(\"#{sentinel}\\n\")" ],
                      env: { "PATH" => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}", "PORTLESS_STATE_DIR" => tmp,
                             "PORTLESS_HTTPS" => "0", "PORTLESS" => nil }, timeout: 30)
          _(r.status).must_equal 0, "#{c[:name]}: #{r.stderr}"
          _(r.stdout).must_equal "#{sentinel}\n"
          _(r.stderr).must_include c[:tunnel_line]
          _(r.stderr).must_include c[:status_line]
        ensure
          stop_child(proxy.child)
          rm_tmp(tmp)
        end
      end
    end
  end

  describe "--cloudflare flag" do
    it "fails with actionable message when cloudflared is not installed" do
      [
        [ %w[myapp --cloudflare echo hi], {} ],
        [ %w[myapp echo hi], { "PORTLESS_CLOUDFLARE" => "1" } ],
        [ %w[run --cloudflare echo hi], {} ]
      ].each do |args, env|
        result = run_cli(args, env: env.merge("PATH" => "/tmp/portless-no-cloudflared"))
        _(result.status).must_equal 1, args.inspect
        _(result.stderr).must_include "cloudflared CLI not found"
      end
    end
  end

  describe "multi-app worktree routing (issue #269)" do
    it "applies root and package worktree config to every app hostname" do
      root = tmpdir("portless-multi-wt-")
      state_dir = tmpdir("portless-multi-state-")
      proxy_port = get_free_port
      cap_file = ->(name) { File.join(state_dir, "url-#{name}.txt") }
      read_cap = ->(name) { File.exist?(cap_file.(name)) ? File.read(cap_file.(name)) : "" }
      File.write(File.join(root, "package.json"),
                 JSON.generate(name: "myrepo", private: true, packageManager: "npm@10.0.0", workspaces: [ "packages/*" ]))
      # Root uses branch style; the leaf overrides it with last-segment.
      File.write(File.join(root, "portless.json"), JSON.generate(worktree: { prefix: "branch" }))
      gitdir = File.join(root, "fake-bare.git", "worktrees", "wt")
      FileUtils.mkdir_p(gitdir)
      File.write(File.join(gitdir, "HEAD"), "ref: refs/heads/team-a/login\n")
      File.write(File.join(root, ".git"), "gitdir: #{gitdir}\n")
      %w[web api].each do |name|
        dir = File.join(root, "packages", name)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "capture.rb"), "File.write(#{cap_file.(name).inspect}, ENV['PORTLESS_URL'].to_s)\n")
        File.write(File.join(dir, "package.json"),
                   JSON.generate(name: name, version: "0.0.0", scripts: { dev: "#{RbConfig.ruby} capture.rb" },
                                 portless: { proxy: true, worktree: { prefix: "branch" } }))
      end
      File.write(File.join(root, "packages", "web", "portless.json"), JSON.generate(worktree: { prefix: "last-segment" }))

      child_env = { "PORTLESS_STATE_DIR" => state_dir, "PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_HTTPS" => "0",
                    "NO_COLOR" => "1", "PORTLESS_PREFIX" => nil }
      ENV.each_key { |k| child_env[k] = nil if k.start_with?("npm_", "PNPM_") }
      cli = spawn_bg(cli_argv, env: child_env, chdir: root, detached: true)
      60.times do
        break if !read_cap.("web").empty? && !read_cap.("api").empty?

        sleep 0.5
      end
      web_url = read_cap.("web")
      api_url = read_cap.("api")
      if web_url.empty? || api_url.empty?
        raise "capture incomplete (web=#{web_url.inspect}, api=#{api_url.inspect}). CLI output:\n#{cli.output}"
      end

      _(web_url).must_include "login.web.myrepo.localhost"
      _(api_url).must_include "team-a-login.api.myrepo.localhost"
      got = run_cli(%w[get web.myrepo], cwd: File.join(root, "packages", "web"),
                                        env: { "PORTLESS_STATE_DIR" => state_dir, "PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_HTTPS" => "0" })
      _(got.status).must_equal 0
      _(got.stdout.strip).must_equal web_url
    ensure
      if cli
        stop_child(cli)
        kill_group(cli.pid)
      end
      run_cli(%w[proxy stop], env: { "PORTLESS_STATE_DIR" => state_dir, "PORTLESS_HTTPS" => "0" }) if state_dir
      rm_tmp(root)
      rm_tmp(state_dir)
    end
  end

  describe "multi-app app port precedence" do
    def multi_env(state_dir)
      env = { "PORTLESS_STATE_DIR" => state_dir, "PORTLESS_HTTPS" => "0", "NO_COLOR" => "1", "PORTLESS_PREFIX" => nil }
      ENV.each_key { |k| env[k] = nil if k.start_with?("npm_", "PNPM_") }
      env
    end

    it "gives a multi-app package its portless.json appPort and lets PORTLESS_APP_PORT override it" do
      root = tmpdir("portless-multi-port-")
      state_dir = tmpdir("portless-multi-port-state-")
      proxy_port = get_free_port
      config_port = get_free_port
      env_port = get_free_port
      env_port = get_free_port while env_port == config_port || env_port == proxy_port
      capture_path = File.join(state_dir, "port.txt")
      File.write(File.join(root, "package.json"),
                 JSON.generate(name: "myrepo", private: true, packageManager: "npm@10.0.0", workspaces: [ "packages/*" ]))
      dir = File.join(root, "packages", "web")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "capture.rb"), "File.write(#{capture_path.inspect}, ENV['PORT'].to_s)\n")
      File.write(File.join(dir, "package.json"), JSON.generate(name: "web", version: "0.0.0", scripts: { dev: "#{RbConfig.ruby} capture.rb" }))
      File.write(File.join(dir, "portless.json"), JSON.generate(appPort: config_port, proxy: true))

      child_env = multi_env(state_dir).merge("PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_APP_PORT" => env_port.to_s)
      read_capture = lambda do
        captured = ""
        60.times do
          captured = File.exist?(capture_path) ? File.read(capture_path) : ""
          break unless captured.empty?

          sleep 0.5
        end
        captured
      end

      cli = spawn_bg(cli_argv, env: child_env, chdir: root, detached: true)
      _(read_capture.()).must_equal env_port.to_s, cli&.output

      stop_child(cli)
      kill_group(cli.pid)
      cli = nil
      FileUtils.rm_f(capture_path)
      child_env["PORTLESS_APP_PORT"] = nil
      cli = spawn_bg(cli_argv, env: child_env, chdir: root, detached: true)
      _(read_capture.()).must_equal config_port.to_s, cli.output
    ensure
      if cli
        stop_child(cli)
        kill_group(cli.pid)
      end
      run_cli(%w[proxy stop], env: { "PORTLESS_STATE_DIR" => state_dir, "PORTLESS_HTTPS" => "0" }) if state_dir
      rm_tmp(root)
      rm_tmp(state_dir)
    end

    it "refuses PORTLESS_APP_PORT when several apps would start" do
      root = tmpdir("portless-multi-port-ambiguous-")
      state_dir = tmpdir("portless-multi-port-ambiguous-state-")
      File.write(File.join(root, "package.json"),
                 JSON.generate(name: "myrepo", private: true, packageManager: "npm@10.0.0", workspaces: [ "packages/*" ]))
      %w[web api].each do |name|
        dir = File.join(root, "packages", name)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "package.json"), JSON.generate(name: name, version: "0.0.0", scripts: { dev: "#{RbConfig.ruby} noop.rb" }))
        File.write(File.join(dir, "portless.json"), JSON.generate(proxy: true))
        File.write(File.join(dir, "noop.rb"), "sleep 5\n")
      end
      result = run_cli([], cwd: root, env: multi_env(state_dir).merge("PORTLESS_APP_PORT" => "45678"), timeout: 15)
      _(result.status).must_equal 2
      _(result.stderr).must_include "PORTLESS_APP_PORT sets one port"
      _(result.stderr).must_include "2 apps"
      _(result.stderr).wont_include "Proxy is running"
    ensure
      rm_tmp(root)
      rm_tmp(state_dir)
    end
  end

  describe "multi-app script selection" do
    it "lets --script override a per-app script and keeps the app script otherwise" do
      root = tmpdir("portless-multi-script-")
      state_dir = tmpdir("portless-multi-script-state-")
      marks = File.join(root, "marks.txt")
      read_marks = -> { File.read(marks).split("\n").reject(&:empty?).sort }
      File.write(File.join(root, "package.json"),
                 JSON.generate(name: "myrepo", private: true, packageManager: "npm@10.0.0", workspaces: [ "packages/*" ]))
      # Both apps pin "start": web in the root apps map, api in its own config.
      File.write(File.join(root, "portless.json"), JSON.generate(apps: { "packages/web" => { script: "start", proxy: false } }))
      %w[web api].each do |name|
        dir = File.join(root, "packages", name)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "mark.rb"), "File.write(ENV['MARK_FILE'], \"#{name}:\#{ARGV[0]}\\n\", mode: 'a')\n")
        portless = { proxy: false }
        portless[:script] = "start" if name == "api"
        File.write(File.join(dir, "package.json"),
                   JSON.generate(name: name, version: "0.0.0",
                                 scripts: { dev: "#{RbConfig.ruby} mark.rb dev", start: "#{RbConfig.ruby} mark.rb start" },
                                 portless: portless))
      end
      child_env = { "PORTLESS_STATE_DIR" => state_dir, "PORTLESS_HTTPS" => "0", "NO_COLOR" => "1", "MARK_FILE" => marks,
                    "PORTLESS_PREFIX" => nil }
      ENV.each_key { |k| child_env[k] = nil if k.start_with?("npm_", "PNPM_") }
      run_workspace = lambda do |args|
        File.write(marks, "")
        r = run_cli(args, cwd: root, env: child_env, timeout: 45)
        { status: r.status, marks: read_marks.(), output: "#{r.stdout}#{r.stderr}" }
      end

      flagged = run_workspace.(%w[--script dev])
      _(flagged[:marks]).must_equal %w[api:dev web:dev], flagged[:output]
      _(flagged[:status]).must_equal 0, flagged[:output]

      bare = run_workspace.([])
      _(bare[:marks]).must_equal %w[api:start web:start], bare[:output]
      _(bare[:status]).must_equal 0, bare[:output]
    ensure
      rm_tmp(root)
      rm_tmp(state_dir)
    end
  end

  describe "zero-argument argument forwarding" do
    def args = UpstreamCli::FORWARD_ARGS

    def write_app(dir, name, proxy = true, package_manager = "npm@10.0.0")
      FileUtils.mkdir_p(dir)
      pkg = { name: name, version: "0.0.0", packageManager: package_manager, scripts: { dev: "#{RbConfig.ruby} mark.rb" } }
      pkg[:portless] = { proxy: false } unless proxy
      File.write(File.join(dir, "package.json"), JSON.generate(pkg))
      File.write(File.join(dir, "mark.rb"), <<~'RUBY')
        require "json"
        name = JSON.parse(File.read(File.join(__dir__, "package.json")))["name"]
        File.write(ENV["MARK_FILE"], "#{name}:#{JSON.generate(ARGV)}\n", mode: "a")
      RUBY
    end

    def child_env(mark_file, extra)
      env = {}
      ENV.each_key { |k| env[k] = nil if k.start_with?("npm_", "PNPM_") }
      env["PATH"] = [ UpstreamCli::REPO_BIN, ENV["PATH"] ].compact.join(File::PATH_SEPARATOR)
      env["PORTLESS"] = nil
      env.merge("NO_COLOR" => "1", "MARK_FILE" => mark_file).merge(extra)
    end

    def read_marks(mark_file)
      return [] unless File.exist?(mark_file)

      File.read(mark_file).split("\n").reject(&:empty?).map do |line|
        sep = line.index(":")
        [ line[0...sep], JSON.parse(line[(sep + 1)..]) ]
      end.sort_by(&:first)
    end

    def spawn_cli(cwd, env, cli_args)
      r = run_cli(cli_args, cwd: cwd, env: env, timeout: 45)
      { status: r.status, output: "#{r.stdout}#{r.stderr}" }
    end

    def turbo_bin
      pkg = JSON.parse(File.read(File.join(UpstreamCli::TURBO_DIR, "package.json")))
      pkg["bin"].is_a?(String) ? pkg["bin"] : pkg["bin"]["turbo"]
    end

    def require_turbo!
      skip "upstream checkout has no node_modules/turbo (run pnpm install in references/portless)" unless File.directory?(UpstreamCli::TURBO_DIR)
    end

    def require_tool!(tool)
      found = ENV["PATH"].split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, tool)) }
      skip "#{tool} is not installed" unless found
    end

    def link_local_turbo(root)
      FileUtils.mkdir_p(File.join(root, "node_modules", ".bin"))
      File.symlink(File.join(UpstreamCli::TURBO_DIR, turbo_bin), File.join(root, "node_modules", ".bin", "turbo"))
      File.symlink(UpstreamCli::TURBO_DIR, File.join(root, "node_modules", "turbo"))
    end

    def write_workspace_root(root, name, extra = {})
      File.write(File.join(root, "package.json"),
                 JSON.generate({ name: name, private: true, packageManager: "npm@10.0.0", workspaces: [ "packages/*" ] }.merge(extra)))
    end

    def write_turbo_json(root, env = [ "MARK_FILE" ])
      File.write(File.join(root, "turbo.json"), JSON.generate(tasks: { dev: { cache: false, env: env } }))
    end

    it "links Turbo's real bin instead of the package-manager shim" do
      require_turbo!
      require_tool!("node")
      root = tmpdir("portless-turbo-bin-")
      link_local_turbo(root)
      pkg = JSON.parse(File.read(File.join(UpstreamCli::TURBO_DIR, "package.json")))
      link = File.join(root, "node_modules", ".bin", "turbo")
      _(File.readlink(link)).must_equal File.join(UpstreamCli::TURBO_DIR, turbo_bin)
      out, err, st = Open3.capture3("node", link, "--version")
      _(st.exitstatus).must_equal 0, err
      _(out.strip).must_equal pkg["version"]
    ensure
      rm_tmp(root)
    end

    it "passes arguments after -- to the single app script through the npm separator" do
      require_tool!("npm")
      root = tmpdir("portless-args-")
      state_dir = tmpdir("portless-args-state-")
      mark_file = File.join(root, "marks.txt")
      proxy_port = get_free_port
      env = child_env(mark_file, "PORTLESS_STATE_DIR" => state_dir, "PORTLESS_PORT" => proxy_port.to_s, "PORTLESS_HTTPS" => "0")
      write_app(root, "args-app")
      result = spawn_cli(root, env, [ "--", *args ])
      _(result[:status]).must_equal 0, result[:output]
      _(read_marks(mark_file)).must_equal [ [ "args-app", args ] ], result[:output]
    ensure
      run_cli([ "proxy", "stop", "-p", proxy_port.to_s ], env: env) if env
      rm_tmp(root)
      rm_tmp(state_dir)
    end

    it "passes arguments after -- to the single app script with PORTLESS=0 through npm and pnpm" do
      require_tool!("npm")
      root = tmpdir("portless-args-skip-")
      mark_file = File.join(root, "marks.txt")
      write_app(root, "args-app")
      npm_result = spawn_cli(root, child_env(mark_file, "PORTLESS" => "0"), [ "--", *args ])
      _(npm_result[:status]).must_equal 0, npm_result[:output]
      _(read_marks(mark_file)).must_equal [ [ "args-app", args ] ], npm_result[:output]

      require_tool!("pnpm")
      FileUtils.rm_f(mark_file)
      write_app(root, "args-app", true, "pnpm@11.1.3")
      pnpm_result = spawn_cli(root, child_env(mark_file, "PORTLESS" => "0"), [ "--", *args ])
      _(pnpm_result[:status]).must_equal 0, pnpm_result[:output]
      _(read_marks(mark_file)).must_equal [ [ "args-app", args ] ], pnpm_result[:output]
    ensure
      rm_tmp(root)
    end

    it "passes arguments after -- to every workspace app" do
      require_tool!("npm")
      root = tmpdir("portless-args-ws-")
      mark_file = File.join(root, "marks.txt")
      write_workspace_root(root, "args-workspace")
      write_app(File.join(root, "packages", "web"), "web", false)
      write_app(File.join(root, "packages", "api"), "api", false)
      result = spawn_cli(root, child_env(mark_file, {}), [ "--", *args ])
      _(result[:status]).must_equal 0, result[:output]
      _(read_marks(mark_file)).must_equal [ [ "api", args ], [ "web", args ] ], result[:output]
    ensure
      rm_tmp(root)
    end

    it "passes arguments through a root Turbo script" do
      require_turbo!
      require_tool!("npm")
      root = tmpdir("portless-args-turbo-")
      mark_file = File.join(root, "marks.txt")
      write_workspace_root(root, "args-turbo", scripts: { dev: "turbo dev" })
      write_turbo_json(root)
      write_app(File.join(root, "packages", "web"), "web", false)
      write_app(File.join(root, "packages", "api"), "api", false)
      result = spawn_cli(root, child_env(mark_file, {}), [ "--", *args ])
      _(result[:status]).must_equal 0, result[:output]
      _(read_marks(mark_file)).must_equal [ [ "api", args ], [ "web", args ] ], result[:output]
    ensure
      rm_tmp(root)
    end

    it "passes arguments through a root Turbo script when PORTLESS=0 skips portless" do
      require_tool!("npm")
      root = tmpdir("portless-args-turbo-skip-")
      bin_dir = tmpdir("portless-args-turbo-skip-bin-")
      log = File.join(root, "turbo.log")
      File.write(File.join(root, "package.json"),
                 JSON.generate(name: "args-turbo-skip", private: true, packageManager: "npm@10.0.0", scripts: { dev: "turbo dev" }))
      write_exe(File.join(bin_dir, "turbo"), "#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$STUB_LOG\"\nexit 0\n")
      env = child_env(log, "PORTLESS" => "0", "STUB_LOG" => log, "PATH" => [ bin_dir, ENV["PATH"] ].join(File::PATH_SEPARATOR))
      result = spawn_cli(root, env, %w[-- --marker one])
      _(result[:status]).must_equal 0, result[:output]
      _(File.read(log).strip).must_equal "dev -- --marker one"
    ensure
      rm_tmp(root)
      rm_tmp(bin_dir)
    end

    it "passes arguments through wrapped Turbo root scripts" do
      require_turbo!
      require_tool!("npm")
      root = tmpdir("portless-args-turbo-wrap-")
      mark_file = File.join(root, "marks.txt")
      write_root = lambda do |package_manager, dev, extra_scripts = {}|
        pnpm = package_manager.start_with?("pnpm")
        pkg = { name: "args-turbo-wrap", private: true, packageManager: package_manager }
        pkg[:workspaces] = [ "packages/*" ] unless pnpm
        pkg[:scripts] = { dev: dev }.merge(extra_scripts)
        File.write(File.join(root, "package.json"), JSON.generate(pkg))
        workspace_file = File.join(root, "pnpm-workspace.yaml")
        pnpm ? File.write(workspace_file, "packages:\n  - packages/*\n") : FileUtils.rm_f(workspace_file)
      end
      write_turbo_json(root)
      write_app(File.join(root, "packages", "web"), "web", false)
      write_app(File.join(root, "packages", "api"), "api", false)
      link_local_turbo(root)

      cases = [
        { package_manager: "npm@10.0.0", dev: "npx turbo dev" },
        { package_manager: "npm@10.0.0", dev: "npm exec turbo dev" },
        { package_manager: "npm@10.0.0", dev: "npm exec turbo dev --" },
        { package_manager: "npm@10.0.0", dev: "turbo dev --" },
        { package_manager: "npm@10.0.0", dev: "npm run turbo-dev", scripts: { "turbo-dev" => "turbo dev" } },
        { package_manager: "npm@10.0.0", dev: "npm run turbo-dev --", scripts: { "turbo-dev" => "turbo dev" } },
        { package_manager: "npm@10.0.0", dev: "npm run turbo-dev", scripts: { "turbo-dev" => "turbo dev -- --fixed" }, fixed: [ "--fixed" ] },
        { package_manager: "npm@10.0.0", dev: "npm run turbo-dev --", scripts: { "turbo-dev" => "turbo dev -- --fixed" }, fixed: [ "--fixed" ] },
        { package_manager: "npm@10.0.0", dev: "FOO=1 npm run turbo-dev", scripts: { "turbo-dev" => "turbo dev" } },
        { package_manager: "npm@10.0.0", dev: "FOO=1 npm run turbo-dev --", scripts: { "turbo-dev" => "turbo dev" } },
        { package_manager: "npm@10.0.0", dev: "env FOO=1 npm run turbo-dev", scripts: { "turbo-dev" => "turbo dev" } },
        { package_manager: "pnpm@11.1.3", dev: "pnpm exec turbo dev" },
        { package_manager: "pnpm@11.1.3", dev: "pnpm run turbo-dev", scripts: { "turbo-dev" => "turbo dev" } },
        { package_manager: "pnpm@11.1.3", dev: "FOO=1 pnpm run turbo-dev", scripts: { "turbo-dev" => "turbo dev" } },
        { package_manager: "pnpm@11.1.3", dev: "pnpm run turbo-dev --", scripts: { "turbo-dev" => "turbo dev" } },
        { package_manager: "pnpm@11.1.3", dev: "pnpm run turbo-dev", scripts: { "turbo-dev" => "turbo dev -- --fixed" }, fixed: [ "--fixed" ] }
      ]
      cases.each do |c|
        require_tool!("pnpm") if c[:package_manager].start_with?("pnpm")
        write_root.(c[:package_manager], c[:dev], c[:scripts] || {})
        FileUtils.rm_f(mark_file)
        result = spawn_cli(root, child_env(mark_file, {}), [ "--", *args ])
        fixed = c[:fixed] || []
        _(result[:status]).must_equal 0, "#{c[:dev]}: #{result[:output]}"
        _(read_marks(mark_file)).must_equal [ [ "api", [ *fixed, *args ] ], [ "web", [ *fixed, *args ] ] ], "#{c[:dev]}: #{result[:output]}"
      end
    ensure
      rm_tmp(root)
    end

    it "keeps the root script's environment when forwarding through a nested script" do
      require_turbo!
      require_tool!("npm")
      root = tmpdir("portless-args-turbo-env-")
      mark_file = File.join(root, "marks.txt")
      forwarded = %w[--marker one]
      write_workspace_root(root, "args-turbo-env", scripts: { dev: "CUSTOM_ENV=root-value npm run turbo-dev", "turbo-dev" => "turbo dev" })
      write_turbo_json(root, %w[MARK_FILE CUSTOM_ENV])
      %w[web api].each do |name|
        dir = File.join(root, "packages", name)
        write_app(dir, name, false)
        File.write(File.join(dir, "mark.rb"), <<~'RUBY')
          require "json"
          name = JSON.parse(File.read(File.join(__dir__, "package.json")))["name"]
          File.write(ENV["MARK_FILE"], "#{name} env=#{ENV['CUSTOM_ENV']} args=#{JSON.generate(ARGV)}\n", mode: "a")
        RUBY
      end
      link_local_turbo(root)
      result = spawn_cli(root, child_env(mark_file, {}), [ "--", *forwarded ])
      _(result[:status]).must_equal 0, result[:output]
      _(File.read(mark_file).strip.split("\n").sort).must_equal [
        "api env=root-value args=#{JSON.generate(forwarded)}",
        "web env=root-value args=#{JSON.generate(forwarded)}"
      ]
    ensure
      rm_tmp(root)
    end

    it "passes arguments through direct Turbo when the root has no script" do
      require_turbo!
      require_tool!("npm")
      root = tmpdir("portless-args-turbo-direct-")
      mark_file = File.join(root, "marks.txt")
      write_workspace_root(root, "args-turbo-direct")
      write_turbo_json(root)
      write_app(File.join(root, "packages", "web"), "web", false)
      write_app(File.join(root, "packages", "api"), "api", false)
      link_local_turbo(root)
      result = spawn_cli(root, child_env(mark_file, {}), [ "--", *args ])
      _(result[:status]).must_equal 0, result[:output]
      _(read_marks(mark_file)).must_equal [ [ "api", args ], [ "web", args ] ], result[:output]
    ensure
      rm_tmp(root)
    end

    it "rejects unsafe root scripts before forwarding arguments" do
      root = tmpdir("portless-args-unsafe-")
      mark_file = File.join(root, "marks.txt")
      forwarded = %w[--marker one]
      write_turbo_json(root)
      write_app(File.join(root, "packages", "web"), "web", false)
      write_app(File.join(root, "packages", "api"), "api", false)
      [
        [ "turbo dev && node mark-root.cjs", 'Change the root "dev" script to a single command, such as "turbo dev"' ],
        [ "turbo dev # note", 'Change the root "dev" script to a single command, such as "turbo dev"' ],
        [ "node mark-root.cjs && node mark-root.cjs", "rb-portless run <command> --marker one" ]
      ].each do |dev, recovery|
        write_workspace_root(root, "args-unsafe", scripts: { dev: dev })
        FileUtils.rm_f(mark_file)
        result = spawn_cli(root, child_env(mark_file, {}), [ "--", *forwarded ])
        _(result[:status]).must_equal 2, "#{dev}: #{result[:output]}"
        _(result[:output]).must_include 'Cannot forward arguments through the "dev" root script. It has shell operators or a comment.'
        _(result[:output]).must_include recovery
        _(read_marks(mark_file)).must_equal [], result[:output]
      end
    ensure
      rm_tmp(root)
    end

    it "rejects forwarded args through a compound script outside Turbo" do
      root = tmpdir("portless-args-compound-")
      mark_file = File.join(root, "marks.txt")
      forwarded = %w[--marker one]
      File.write(File.join(root, "package.json"), JSON.generate(name: "args-compound", scripts: { dev: "node a.cjs && node b.cjs" }))
      [ { "PORTLESS" => "0" }, {} ].each do |extra|
        FileUtils.rm_f(mark_file)
        result = spawn_cli(root, child_env(mark_file, extra), [ "--", *forwarded ])
        _(result[:status]).must_equal 2, result[:output]
        _(result[:output]).must_include 'Cannot forward arguments through the "dev" script. It has shell operators or a comment.'
        _(read_marks(mark_file)).must_equal [], result[:output]
      end
    ensure
      rm_tmp(root)
    end

    it "rejects forwarded args through a compound package script in a non-Turbo workspace" do
      root = tmpdir("portless-args-compound-ws-")
      mark_file = File.join(root, "marks.txt")
      forwarded = %w[--marker one]
      write_workspace_root(root, "args-compound-ws")
      dir = File.join(root, "packages", "web")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "package.json"), JSON.generate(name: "web", version: "0.0.0", scripts: { dev: "node a.cjs && node b.cjs" }))
      result = spawn_cli(root, child_env(mark_file, {}), [ "--", *forwarded ])
      _(result[:status]).must_equal 2, result[:output]
      _(result[:output]).must_include 'Cannot forward arguments through the "dev" script. It has shell operators or a comment.'
      _(read_marks(mark_file)).must_equal [], result[:output]
    ensure
      rm_tmp(root)
    end

    it "forwards args through a dev script that delegates via npm run and ignores compound leaf scripts in Turbo mode" do
      require_turbo!
      require_tool!("npm")
      single = tmpdir("portless-args-delegated-")
      turbo_ws = tmpdir("portless-args-turbo-leaf-")
      single_marks = File.join(single, "marks.txt")
      turbo_marks = File.join(turbo_ws, "marks.txt")
      write_app(single, "delegated-app")
      single_pkg = JSON.parse(File.read(File.join(single, "package.json")))
      single_pkg["scripts"] = { "dev" => "npm run start", "start" => single_pkg["scripts"]["dev"] }
      File.write(File.join(single, "package.json"), JSON.generate(single_pkg))
      single_result = spawn_cli(single, child_env(single_marks, "PORTLESS" => "0"), [ "--", *args ])
      _(single_result[:status]).must_equal 0, single_result[:output]
      _(read_marks(single_marks)).must_equal [ [ "delegated-app", args ] ], single_result[:output]

      write_workspace_root(turbo_ws, "args-turbo-leaf", scripts: { dev: "turbo run dev --filter=web" })
      write_turbo_json(turbo_ws)
      write_app(File.join(turbo_ws, "packages", "web"), "web", false)
      unused_dir = File.join(turbo_ws, "packages", "unused")
      FileUtils.mkdir_p(unused_dir)
      File.write(File.join(unused_dir, "package.json"),
                 JSON.generate(name: "unused", version: "0.0.0", scripts: { dev: "node a.cjs && node b.cjs" }, portless: { proxy: false }))
      link_local_turbo(turbo_ws)
      turbo_result = spawn_cli(turbo_ws, child_env(turbo_marks, {}), [ "--", *args ])
      _(turbo_result[:status]).must_equal 0, turbo_result[:output]
      _(read_marks(turbo_marks)).must_equal [ [ "web", args ] ], turbo_result[:output]
    ensure
      rm_tmp(single)
      rm_tmp(turbo_ws)
    end

    it "passes arguments to a root script that does not run Turbo" do
      require_tool!("npm")
      root = tmpdir("portless-args-root-script-")
      mark_file = File.join(root, "marks.txt")
      write_root = lambda do |package_manager|
        File.write(File.join(root, "package.json"),
                   JSON.generate(name: "args-root-script", private: true, packageManager: package_manager,
                                 workspaces: [ "packages/*" ], scripts: { dev: "#{RbConfig.ruby} mark-root.rb" }))
        File.write(File.join(root, "mark-root.rb"), "require 'json'\nFile.write(ENV['MARK_FILE'], \"root:\#{JSON.generate(ARGV)}\\n\", mode: 'a')\n")
      end
      write_root.("npm@10.0.0")
      File.write(File.join(root, "turbo.json"), JSON.generate(tasks: { dev: { cache: false } }))
      write_app(File.join(root, "packages", "web"), "web", false)
      write_app(File.join(root, "packages", "api"), "api", false)
      npm_result = spawn_cli(root, child_env(mark_file, {}), [ "--", *args ])
      _(npm_result[:status]).must_equal 0, npm_result[:output]
      _(read_marks(mark_file)).must_equal [ [ "root", args ] ], npm_result[:output]

      require_tool!("pnpm")
      FileUtils.rm_f(mark_file)
      write_root.("pnpm@11.1.3")
      pnpm_result = spawn_cli(root, child_env(mark_file, {}), [ "--", *args ])
      _(pnpm_result[:status]).must_equal 0, pnpm_result[:output]
      _(read_marks(mark_file)).must_equal [ [ "root", args ] ], pnpm_result[:output]
    ensure
      rm_tmp(root)
    end
  end
end
