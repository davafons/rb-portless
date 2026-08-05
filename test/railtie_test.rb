# frozen_string_literal: true

require_relative "test_helper"
require "portless/rails_hosts"

# The host-derivation logic (the Railtie is thin glue around this). Tested
# without booting Rails.
class RailsHostsTest < Minitest::Test
  def test_no_hosts_relaxed_when_not_under_portless
    assert_empty Portless::RailsHosts.allowed(nil)
    assert_empty Portless::RailsHosts.allowed("")
  end

  def test_localhost_tld_allows_wildcard_localhost
    patterns = Portless::RailsHosts.allowed("https://shirabe.org.localhost")
    assert_includes patterns, /.+\.localhost/
    assert_equal 1, patterns.size # the regex covers .localhost; no extra needed
  end

  def test_custom_tld_allows_that_host_and_subdomains
    patterns = Portless::RailsHosts.allowed("https://myapp.test")
    assert_includes patterns, "myapp.test"
    # A regexp, not Rails' ".host" shorthand — that only matches ONE label,
    # 403ing a.b.myapp.test while a.b.myapp.localhost sails through.
    regexp = patterns.find { |p| p.is_a?(Regexp) && p.source.include?("myapp") }
    refute_nil regexp
    assert_match(/\A#{regexp}\z/, "a.myapp.test")
    assert_match(/\A#{regexp}\z/, "a.b.myapp.test")
    refute_match(/\A#{regexp}\z/, "myapp.test.evil.com")
  end

  def test_lan_host_is_allowed_when_running_with_lan
    patterns = Portless::RailsHosts.allowed("https://myapp.localhost", "myapp.local")
    assert_includes patterns, "myapp.local"
    assert_empty Portless::RailsHosts.allowed(nil, "myapp.local") # LAN alone ≠ portless
  end

  # Tunnels forward with their own Host (*.ts.net / *.ngrok.app) — the railtie
  # must whitelist them or every shared request 403s.
  def test_share_tunnel_hosts_are_allowed_and_get_cable_origins
    env = { "PORTLESS_TAILSCALE_URL" => "https://node.tail1234.ts.net:8443",
            "PORTLESS_NGROK_URL" => "https://abc.ngrok.app" }
    ENV.update(env)

    patterns = Portless::RailsHosts.allowed("https://myapp.localhost")
    assert_includes patterns, "node.tail1234.ts.net"
    assert_includes patterns, "abc.ngrok.app"

    origins = Portless::RailsHosts.cable_origins("https://myapp.localhost")
    assert(origins.any? { |o| o.match?("https://node.tail1234.ts.net:8443") })
    assert(origins.any? { |o| o.match?("https://abc.ngrok.app") })
  ensure
    env.each_key { |k| ENV.delete(k) }
  end

  def test_no_url_options_when_not_under_portless
    assert_nil Portless::RailsHosts.url_options(nil)
    assert_nil Portless::RailsHosts.url_options("")
  end

  def test_url_options_carry_host_and_scheme_without_a_default_port
    options = Portless::RailsHosts.url_options("https://shirabe.localhost")
    assert_equal({ host: "shirabe.localhost", protocol: "https" }, options)
  end

  def test_url_options_carry_a_non_default_port
    options = Portless::RailsHosts.url_options("http://myapp.test:8080")
    assert_equal({ host: "myapp.test", protocol: "http", port: 8080 }, options)
  end

  def test_no_cable_origins_when_not_under_portless
    assert_empty Portless::RailsHosts.cable_origins(nil)
  end

  def test_cable_origins_include_the_lan_host
    origins = Portless::RailsHosts.cable_origins("https://myapp.localhost", "myapp.local")
    assert(origins.any? { |o| o.match?("https://myapp.local") })
  end

  # An app-configured `port: 3000` must not survive into portless links when
  # the portless URL carries no port (443/80) — but an explicit one wins.
  def test_merge_url_options_drops_a_stale_port
    merged = Portless::RailsHosts.merge_url_options(
      { host: "localhost", port: 3000 }, { host: "myapp.localhost", protocol: "https" }
    )
    assert_equal({ host: "myapp.localhost", protocol: "https" }, merged)

    merged = Portless::RailsHosts.merge_url_options(
      { host: "localhost", port: 3000 }, { host: "myapp.localhost", protocol: "https", port: 1355 }
    )
    assert_equal 1355, merged[:port]
  end

  def test_cable_origins_match_the_host_and_its_subdomains
    origin = Portless::RailsHosts.cable_origins("https://shirabe.localhost").first

    assert_match origin, "https://shirabe.localhost"
    assert_match origin, "https://kobe.shirabe.localhost"
    refute_match origin, "http://shirabe.localhost"      # wrong scheme
    refute_match origin, "https://evil.com"              # unrelated host
    refute_match origin, "https://shirabe.localhost.evil.com"
  end
end
