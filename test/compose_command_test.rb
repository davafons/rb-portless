# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"

# The `compose` command's process wiring (cli.ts handleCompose), against a
# stub `docker` on PATH that records its calls and answers config/ps/up/down.
class ComposeCommandTest < Minitest::Test
  STUB = <<~'RUBY'
    #!/usr/bin/env -S RUBYOPT= ruby --disable-gems
    require "json"
    dir = ENV.fetch("STUB_DOCKER_DIR")
    File.open(File.join(dir, "calls.log"), "a") { |f| f.puts(JSON.generate(ARGV)) }
    args = ARGV.drop(1) # "compose"
    model_file = File.join(dir, "model.path")
    if args.include?("config")
      print File.read(File.join(dir, "config.json"))
    elsif args.include?("ps")
      exit 0 unless File.exist?(model_file) && !File.exist?(File.join(dir, "down"))
      model = JSON.parse(File.read(File.read(model_file)))
      model["services"].each do |service, svc|
        pubs = (svc["ports"] || []).filter_map do |p|
          { "TargetPort" => p["target"], "PublishedPort" => p["published"].to_i, "Protocol" => "tcp" } if p["published"]
        end
        puts JSON.generate({ "Project" => model["name"], "Service" => service, "State" => "running", "Publishers" => pubs })
      end
    elsif args.include?("up")
      File.write(model_file, args[args.index("-f") + 1]) if args.include?("-f")
    elsif args.include?("down")
      File.write(File.join(dir, "down"), "")
    end
    exit Integer(ENV.fetch("STUB_DOCKER_EXIT", "0"))
  RUBY

  CONFIG = {
    "name" => "shop",
    "services" => {
      "web" => { "image" => "nginx", "ports" => [ { "target" => 80, "published" => "8080", "protocol" => "tcp" } ] },
      "db" => { "image" => "postgres", "ports" => [ { "target" => 5432, "published" => "5432", "protocol" => "tcp" } ] }
    }
  }.freeze

  def setup
    @tmp = Dir.mktmpdir("rb-portless-compose-")
    @stub_dir = File.join(@tmp, "stub")
    @state_dir = File.join(@tmp, "state")
    FileUtils.mkdir_p([ @stub_dir, @state_dir ])
    File.write(File.join(@stub_dir, "docker"), STUB)
    File.chmod(0o755, File.join(@stub_dir, "docker"))
    File.write(File.join(@stub_dir, "config.json"), JSON.generate(CONFIG))
    @env = ENV.to_h.slice("PATH", "PORTLESS_STATE_DIR", "STUB_DOCKER_DIR", "PORTLESS", "COMPOSE_PROJECT_NAME")
    ENV["PATH"] = "#{@stub_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
    ENV["PORTLESS_STATE_DIR"] = @state_dir
    ENV["STUB_DOCKER_DIR"] = @stub_dir
    ENV.delete("PORTLESS")
    ENV.delete("COMPOSE_PROJECT_NAME")
  end

  def teardown
    %w[PATH PORTLESS_STATE_DIR STUB_DOCKER_DIR PORTLESS COMPOSE_PROJECT_NAME].each { |k| ENV[k] = @env[k] }
    FileUtils.rm_rf(@tmp)
  end

  def calls = File.readlines(File.join(@stub_dir, "calls.log")).map { |l| JSON.parse(l) }
  def store = Portless::RouteStore.new(@state_dir)

  def cli(*args)
    code = nil
    out, err = capture_io { code = Portless::CLI.new([ "compose", *args ]).main }
    [ code, out, err ]
  end

  # Run with the proxy treated as already up on 1355 over HTTPS.
  def with_proxy(&block)
    state = Portless::Daemon::ProxyState.new(dir: @state_dir, port: 1355, tls: true, tld: "localhost",
                                             tlds: [ "localhost" ], lan_mode: false, lan_ip: nil, started: false)
    running = Struct.new(:tlds, :lan_mode, :lan_ip).new([ "localhost" ], false, nil)
    Portless::Daemon.stub(:discover_state, state) do
      Portless::Daemon.stub(:ensure_proxy_running, { started: false }) do
        Portless::Daemon.stub(:read_current_proxy_config, running) do
          Portless::Daemon.stub(:report_hosts_sync, nil, &block)
        end
      end
    end
  end

  def test_prints_help_without_a_subcommand
    code, out, = cli
    assert_equal 0, code
    assert_includes out, "rb-portless compose - Run a Docker Compose project behind rb-portless."
    code, out, = cli("--help")
    assert_equal 0, code
    assert_includes out, "Service labels:"
  end

  def test_rejects_unknown_global_flags_as_usage_errors
    code, _, err = cli("--bad", "up")
    assert_equal 2, code
    assert_includes err, 'Unknown flag "--bad" for rb-portless compose.'
    assert_includes err, "See: rb-portless compose --help"
    refute File.exist?(File.join(@stub_dir, "calls.log"))
  end

  def test_passes_other_subcommands_and_child_help_through_unchanged
    assert_equal 0, cli("-f", "a.yml", "ps", "-a").first
    assert_equal 0, cli("--", "up", "--help").first
    assert_equal [ %w[compose -f a.yml ps -a], %w[compose up --help] ], calls
  end

  def test_passthrough_keeps_the_docker_exit_code
    ENV["STUB_DOCKER_EXIT"] = "3"
    assert_equal 3, cli("logs").first
  ensure
    ENV.delete("STUB_DOCKER_EXIT")
  end

  def test_portless_skip_runs_docker_compose_directly
    ENV["PORTLESS"] = "0"
    assert_equal 0, cli("up", "-d").first
    assert_equal [ %w[compose up -d] ], calls
  end

  def test_up_detached_registers_alias_routes_and_down_removes_them
    code, _, err = with_proxy { cli("up", "-d") }
    assert_equal 0, code, err
    assert_includes err, "rb-portless compose shop"
    assert_includes err, "db:5432 keeps host port 5432 (not HTTP)"
    assert_includes err, "-> https://web.shop.localhost:1355  (web:80)"

    route = store.load_routes.find { |r| r.hostname == "web.shop.localhost" }
    assert route, "web route registered"
    assert_equal 0, route.pid
    assert_includes 14_000..14_999, route.port

    model_path = File.join(@state_dir, "compose", "shop.json")
    model = JSON.parse(File.read(model_path))
    assert_equal [ { "target" => 80, "protocol" => "tcp", "host_ip" => "127.0.0.1", "published" => route.port.to_s } ],
                 model["services"]["web"]["ports"]
    assert_equal ".localhost", model["services"]["web"]["environment"]["__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS"]
    assert_equal({ "web:80" => route.port }, JSON.parse(File.read(File.join(@state_dir, "compose", "shop.ports.json"))))

    up = calls.find { |c| c.include?("up") }
    assert_equal [ "compose", "-p", "shop", "--project-directory", Dir.pwd, "-f", model_path, "up", "-d" ], up
    assert(calls.any? { |c| c.include?("config") && c.include?("--profile") && c.include?("*") })

    # A second up reuses the stored port.
    with_proxy { cli("up", "-d") }
    assert_equal route.port, store.load_routes.find { |r| r.hostname == "web.shop.localhost" }.port

    code, _, err = with_proxy { cli("down") }
    assert_equal 0, code, err
    assert_empty store.load_routes
    refute File.exist?(model_path)
  end

  def test_up_reports_a_route_held_by_a_live_process_and_exits_1
    store.add_route(hostname: "web.shop.localhost", port: 4321, pid: Process.pid)
    code, _, err = with_proxy { cli("up", "-d") }
    assert_equal 1, code
    assert_includes err, "Error: web.shop.localhost is already registered by another process (PID #{Process.pid}). " \
                         "Stop it, or rename the service with portless.name."
  end

  def test_up_refuses_a_project_whose_label_collides_with_another
    FileUtils.mkdir_p(File.join(@state_dir, "compose"))
    File.write(File.join(@state_dir, "compose", "sh-op.json"), JSON.generate({ "name" => "sh_op" }))
    File.write(File.join(@stub_dir, "config.json"), JSON.generate(CONFIG.merge("name" => "sh-op")))
    code, _, err = with_proxy { cli("up", "-d") }
    assert_equal 1, code
    assert_includes err, "Error: Projects \"sh_op\" and \"sh-op\" share the hostname suffix sh-op. " \
                         "Run rb-portless compose -p sh_op down, or rename one project."
  end

  def test_up_fails_with_exit_1_when_config_fails
    ENV["STUB_DOCKER_EXIT"] = "1"
    code, _, err = with_proxy { cli("up") }
    assert_equal 1, code
    assert_includes err, "Error: docker compose config failed."
  ensure
    ENV.delete("STUB_DOCKER_EXIT")
  end
end
