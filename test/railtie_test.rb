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
    assert_includes patterns, ".myapp.test"
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

  def test_cable_origins_match_the_host_and_its_subdomains
    origin = Portless::RailsHosts.cable_origins("https://shirabe.localhost").first

    assert_match origin, "https://shirabe.localhost"
    assert_match origin, "https://kobe.shirabe.localhost"
    refute_match origin, "http://shirabe.localhost"      # wrong scheme
    refute_match origin, "https://evil.com"              # unrelated host
    refute_match origin, "https://shirabe.localhost.evil.com"
  end
end
