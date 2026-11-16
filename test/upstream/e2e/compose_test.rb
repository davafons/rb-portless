# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"
require "etc"

# Mirror of tests/e2e/src/compose.test.ts
#
# Runs the real `rb-portless compose` against Docker; skipped where no Docker
# daemon (or no compose plugin) is available. Like upstream, the four tests
# share one `compose up` and run in order.

module ComposeE2E
  extend E2ECli

  PROJECT = "portless-e2e-compose"

  module_function

  # Tests run with a temp HOME, so docker would lose the user's CLI config
  # (current context, the compose plugin); point DOCKER_CONFIG back at it.
  def docker_env
    return {} if ENV["DOCKER_CONFIG"]

    config = File.join(Etc.getpwuid.dir, ".docker")
    Dir.exist?(config) ? { "DOCKER_CONFIG" => config } : {}
  end

  def docker?
    if @docker.nil?
      @docker = system(docker_env, "docker", "info", out: File::NULL, err: File::NULL) &&
                system(docker_env, "docker", "compose", "version", out: File::NULL, err: File::NULL)
    end
    @docker
  end

  def cwd = UpstreamE2E::UPSTREAM_E2E + "/fixtures/compose-app"

  # beforeAll: one state dir, proxy port and `compose up -d` for the file.
  def setup!
    return @up if @up

    @proxy_port = free_port
    @state_dir = make_state_dir("rbp-e2e-compose-")
    @env = env_for(@state_dir, @proxy_port).merge(docker_env)
    @up = portless("compose", "up", "-d", timeout: 300)
    Minitest.after_run { teardown! }
    @up
  end

  # afterAll.
  def teardown!
    system(docker_env, "docker", "compose", "-p", PROJECT, "down", "--remove-orphans", out: File::NULL, err: File::NULL)
    portless("proxy", "stop", "-p", @proxy_port.to_s)
    kill_port(@proxy_port)
    FileUtils.rm_rf(@state_dir)
  end

  def portless(*args, timeout: 120)
    out, err, st = cli(@env, *args, chdir: cwd, timeout: timeout)
    { status: st.exitstatus, stdout: out, stderr: err }
  end

  def proxy_port = @proxy_port

  # Host port compose published for web:80, like "127.0.0.1:14123".
  def web_port
    out, = Open3.capture2(docker_env, "docker", "compose", "-p", PROJECT, "port", "web", "80")
    out.strip
  end
end

describe "compose" do
  include E2ECli

  i_suck_and_my_tests_are_order_dependent!

  before do
    skip "Docker is not available" unless ComposeE2E.docker?
    skip "upstream fixtures missing (clone references/portless)" unless Dir.exist?(ComposeE2E.cwd)
    up = ComposeE2E.setup!
    _(up[:status]).must_equal 0, up[:stdout] + up[:stderr]
  end

  def wait_for(host, timeout = 30)
    last = 0
    wait_until(timeout, interval: 0.5) { (last = status_of(ComposeE2E.proxy_port, host)) == 200 }
    last
  end

  it "routes two services that publish the same host port" do
    _(wait_for("web.#{ComposeE2E::PROJECT}.localhost")).must_equal 200
    _(wait_for("backend.#{ComposeE2E::PROJECT}.localhost")).must_equal 200
  end

  it "keeps the published port and the route after a container is recreated" do
    before = ComposeE2E.web_port
    _(before).must_match(/\A127\.0\.0\.1:\d+\z/)
    recreate = ComposeE2E.portless("compose", "up", "-d", "--force-recreate", "web")
    _(recreate[:status]).must_equal 0, recreate[:stdout] + recreate[:stderr]
    _(ComposeE2E.web_port).must_equal before
    _(wait_for("web.#{ComposeE2E::PROJECT}.localhost")).must_equal 200
  end

  it "keeps the published port and the route across restart and stop/start" do
    before = ComposeE2E.web_port
    [
      [ "restart", "web" ],
      [ "stop", "web" ],
      [ "start", "web" ]
    ].each do |args|
      run = ComposeE2E.portless("compose", *args)
      _(run[:status]).must_equal 0, run[:stdout] + run[:stderr]
    end
    _(ComposeE2E.web_port).must_equal before
    _(wait_for("web.#{ComposeE2E::PROJECT}.localhost")).must_equal 200
  end

  it "removes the routes on down" do
    down = ComposeE2E.portless("compose", "down")
    _(down[:status]).must_equal 0, down[:stdout] + down[:stderr]
    list = ComposeE2E.portless("list")
    _(list[:stdout]).wont_include ComposeE2E::PROJECT
  end
end
