# frozen_string_literal: true

require_relative "test_helper"

class SmokeTest < Minitest::Test
  def test_version_present
    assert_match(/\A\d+\.\d+\.\d+/, Portless::VERSION)
  end

  def test_free_port_in_range_and_bindable
    port = Portless::FreePort.find
    assert_includes(Portless::Constants::MIN_APP_PORT..Portless::Constants::MAX_APP_PORT, port)
    refute_includes Portless::Constants::BLOCKED_PORTS, port
  end

  def test_config_infers_hostname
    Dir.mktmpdir do |dir|
      config = Portless::Config.new({ "name" => "myapp" }, dir)
      assert_equal "myapp", config.name
      assert_equal "myapp.localhost", config.hostname
    end
  end

  def test_config_custom_tld_wildcards_to_one_app
    config = Portless::Config.new({ "name" => "shirabe", "tld" => "shirabe.org.localhost" }, Dir.pwd)
    assert_equal "shirabe.org.localhost", config.hostname
  end

  def test_config_parses_apps_map
    config = Portless::Config.new({ "apps" => { "web" => "bin/rails server", "api" => "node a.js" } }, Dir.pwd)
    assert_equal({ "web" => "bin/rails server", "api" => "node a.js" }, config.apps)
  end

  def test_config_warns_only_on_risky_tlds
    assert_nil Portless::Config.new({ "name" => "x", "tld" => "localhost" }, Dir.pwd).tld_warning
    assert_nil Portless::Config.new({ "name" => "x", "tld" => "x.localhost" }, Dir.pwd).tld_warning
    refute_nil Portless::Config.new({ "name" => "x", "tld" => "dev" }, Dir.pwd).tld_warning
    refute_nil Portless::Config.new({ "name" => "x", "tld" => "x.local" }, Dir.pwd).tld_warning
  end

  def test_route_store_add_remove_roundtrip
    store = Portless::RouteStore.new
    store.add(hostname: "x.localhost", port: 4123, pid: Process.pid)
    route = store.routes.find { |r| r.hostname == "x.localhost" }
    assert_equal 4123, route.port

    store.remove("x.localhost", owner_pid: Process.pid)
    assert_nil store.routes.find { |r| r.hostname == "x.localhost" }
  end

  def test_proxy_wildcard_routing
    store = Portless::RouteStore.new
    store.add(hostname: "shirabe.org.localhost", port: 4200, pid: Process.pid)
    proxy = Portless::Proxy.new(port: 443, route_store: store)
    assert_equal 4200, proxy.route_for("kobe.shirabe.org.localhost").port
    assert_equal 4200, proxy.route_for("shirabe.org.localhost").port
  ensure
    store.remove("shirabe.org.localhost", owner_pid: Process.pid)
  end

  def test_hosts_block_build_and_strip
    block = Portless::Hosts.build_block(%w[a.localhost b.localhost])
    assert_includes block, "127.0.0.1\ta.localhost"
    stripped = Portless::Hosts.strip_block("existing\n#{block}\n")
    refute_includes stripped, "a.localhost"
  end
end
