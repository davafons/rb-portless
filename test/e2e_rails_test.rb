# frozen_string_literal: true

require_relative "e2e_helper"

# The Rails integration, end-to-end: a real Rails app booted with the
# `portless/rails` railtie, running behind the real proxy exactly as
# `rb-portless run bin/rails server` would wire it (PORT/HOST/PORTLESS_URL).
# Asserts the promises the README makes: host authorization lets the named
# host and its tenant subdomains through, request.host/ssl? reflect the
# portless URL, and request-less URL generation (routes defaults + Action
# Mailer) targets the portless URL instead of localhost:<random-port>.
class E2ERailsTest < Minitest::Test
  HOST = "e2erails.localhost"

  RAILS_APP = <<~'RUBY'
    ENV["RAILS_ENV"] = "development"
    require "rails"
    require "action_controller/railtie"
    require "action_mailer/railtie"
    require "action_cable/engine"
    require "portless/rails"

    class E2eApp < Rails::Application
      config.load_defaults Rails::VERSION::STRING.to_f
      config.eager_load = false
      config.secret_key_base = "portless-e2e" * 4
      config.logger = ActiveSupport::Logger.new(IO::NULL)
      config.action_mailer.delivery_method = :test
      # Idiomatic app config the railtie must survive and override: a bare
      # Regexp origin (concat would crash boot) and a dev port in mailer URLs.
      config.action_cable.allowed_request_origins = %r{https?://localhost:\d+}
      config.action_mailer.default_url_options = { host: "localhost", port: 3000 }
    end

    Rails.application.initialize!

    class InfoController < ActionController::Base
      def show
        render json: {
          host: request.host,
          ssl: request.ssl?,
          request_url: request.url,
          generated_url: url_for(action: :show, only_path: false),
          route_defaults: Rails.application.routes.default_url_options,
          mailer_defaults: ActionMailer::Base.default_url_options,
          cable_origins: Rails.application.config.action_cable.allowed_request_origins&.map(&:to_s)
        }
      end
    end

    Rails.application.routes.draw { get "/info", to: "info#show" }

    require "rackup/handler/webrick"
    Rackup::Handler::WEBrick.run(
      Rails.application,
      Host: ENV.fetch("HOST", "127.0.0.1"), Port: Integer(ENV.fetch("PORT")),
      AccessLog: [], Logger: WEBrick::Log.new(IO::NULL)
    )
  RUBY

  def self.boot_app
    return @pid if @pid

    lib = File.expand_path("../lib", __dir__)
    @workdir = Dir.mktmpdir
    app_file = File.join(@workdir, "app.rb")
    File.write(app_file, RAILS_APP)

    @port = E2E.free_port
    @pid = Process.spawn(
      { "PORT" => @port.to_s, "HOST" => "127.0.0.1",
        "PORTLESS_URL" => "https://#{HOST}:#{E2E.proxy_port}",
        "PORTLESS_STATE_DIR" => Portless::State.dir },
      RbConfig.ruby, "-I", lib, app_file,
      chdir: @workdir, in: File::NULL, out: File::NULL, err: File.join(@workdir, "rails.log")
    )
    E2E.register(HOST, @port)

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    loop do
      begin
        TCPSocket.new("127.0.0.1", @port).close
        break
      rescue StandardError
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise "rails app did not boot:\n#{File.read(File.join(@workdir, 'rails.log'))}"
        end

        sleep 0.2
      end
    end

    Minitest.after_run do
      begin
        Process.kill("TERM", @pid)
        Process.wait(@pid)
      rescue StandardError
        nil
      end
      E2E.deregister(HOST)
      FileUtils.remove_entry(@workdir) if @workdir
    end
    @pid
  end

  def setup
    self.class.boot_app
  end

  def info(host)
    res = E2E.get(host, "/info")
    [ res, res.code == "200" ? JSON.parse(res.body) : nil ]
  end

  def test_host_authorization_allows_the_portless_host_over_https
    res, data = info(HOST)
    assert_equal "200", res.code, "expected host authorization to allow #{HOST}"
    assert_equal HOST, data["host"]
    assert data["ssl"], "request.ssl? should be true via X-Forwarded-Proto"
    assert_equal "https://#{HOST}:#{E2E.proxy_port}/info", data["request_url"]
  end

  def test_tenant_subdomains_are_allowed_and_visible_to_the_app
    res, data = info("tenant.#{HOST}")
    assert_equal "200", res.code, "expected host authorization to allow tenant subdomains"
    assert_equal "tenant.#{HOST}", data["host"]
  end

  def test_request_less_url_generation_targets_the_portless_url
    _res, data = info(HOST)

    expected = { "host" => HOST, "protocol" => "https", "port" => E2E.proxy_port }
    assert_equal expected, data["route_defaults"].slice("host", "protocol", "port")
    assert_equal HOST, data["mailer_defaults"]["host"]
    assert_equal "https", data["mailer_defaults"]["protocol"]
    # The app configured port: 3000 — the portless port must win, and when the
    # proxy is on 443 (no port in PORTLESS_URL) it must be dropped entirely.
    assert_equal E2E.proxy_port, data["mailer_defaults"]["port"]
    assert_equal "https://#{HOST}:#{E2E.proxy_port}/info", data["generated_url"]
  end

  def test_action_cable_origins_accept_the_portless_origin_and_subdomains
    _res, data = info(HOST)
    origins = data["cable_origins"]
    refute_nil origins, "railtie should register allowed_request_origins"
    # The app's own (bare Regexp) origin must survive alongside ours.
    assert(origins.any? { |o| o.include?("localhost:") })

    patterns = origins.map { |o| Regexp.new(o.sub(/\A\(\?-mix:/, "").sub(/\)\z/, "")) }
    portless_origin = "https://#{HOST}:#{E2E.proxy_port}"
    assert(patterns.any? { |p| p.match?(portless_origin) })
    assert(patterns.any? { |p| p.match?("https://tenant.#{HOST}:#{E2E.proxy_port}") })
    refute(patterns.any? { |p| p.match?("https://evil.example.com") })
  end

  # Regression: the railtie must not assume Action Cable is loaded — touching
  # config.action_cable in an app without it crashed the whole boot.
  def test_railtie_boots_in_an_app_without_action_cable
    lib = File.expand_path("../lib", __dir__)
    script = <<~'RUBY'
      ENV["RAILS_ENV"] = "development"
      require "rails"
      require "action_controller/railtie"
      require "portless/rails"
      class NoCableApp < Rails::Application
        config.load_defaults Rails::VERSION::STRING.to_f
        config.eager_load = false
        config.secret_key_base = "portless-e2e" * 4
        config.logger = ActiveSupport::Logger.new(IO::NULL)
      end
      Rails.application.initialize!
      print "booted-without-cable"
    RUBY

    out = IO.popen(
      { "PORTLESS_URL" => "https://#{HOST}" },
      [ RbConfig.ruby, "-I", lib, "-e", script ], err: [ :child, :out ], &:read
    )
    assert_includes out, "booted-without-cable"
  end
end
