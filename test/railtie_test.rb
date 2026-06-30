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
end
